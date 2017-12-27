%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
-module(lorawan_application_backend).
-behaviour(lorawan_application).

-export([init/1, handle_join/3, handle_uplink/4, handle_rxq/4]).
-export([handle_downlink/2]).

-include("lorawan.hrl").
-include("lorawan_db.hrl").

init(_App) ->
    ok.

handle_join({_Network, _Profile, _Device}, {_MAC, _RxQ}, _DevAddr) ->
    % accept any device
    ok.

handle_uplink({_Network, _Profile, _Node}, _RxQ, {lost, State}, _Frame) ->
    retransmit;
handle_uplink({_Network, #profile{app=AppID}, Node}, _RxQ, _LastAcked, Frame) ->
    case mnesia:dirty_read(handlers, AppID) of
        [#handler{fields=Fields}=Handler] ->
            Vars = parse_uplink(Handler, Frame),
            case any_is_member([<<"freq">>, <<"datr">>, <<"codr">>, <<"best_gw">>, <<"all_gw">>], Fields) of
                true ->
                    % we have to wait for the rx quality indicators
                    {ok, {Handler, Vars}};
                false ->
                    lorawan_backend_factory:uplink(AppID, Node, Vars),
                    {ok, undefined}
            end;
        [] ->
            {error, {unknown_application, AppID}}
    end.

handle_rxq({_Network, _Profile, #node{devaddr=DevAddr}}, _Gateways, #frame{port=Port}, undefined) ->
    % we did already handle this uplink
    lorawan_application:send_stored_frames(DevAddr, Port);
handle_rxq({_Network, #profile{app=AppID}, #node{devaddr=DevAddr}},
        Gateways, #frame{port=Port}, {#handler{fields=Fields}, Vars}) ->
    lorawan_backend_factory:uplink(AppID, parse_rxq(Gateways, Fields, Vars)),
    lorawan_application:send_stored_frames(DevAddr, Port).

any_is_member(List1, List2) ->
    lists:any(
        fun(Item1) ->
            lists:member(Item1, List2)
        end,
        List1).

parse_uplink(#handler{app=AppID, parse=Parse, fields=Fields},
        #frame{devaddr=DevAddr, fcnt=FCnt, port=Port, data=Data}) ->
    Vars =
        vars_add(devaddr, DevAddr, Fields,
        vars_add(deveui, get_deveui(DevAddr), Fields,
        vars_add(fcnt, FCnt, Fields,
        vars_add(port, Port, Fields,
        vars_add(data, Data, Fields,
        vars_add(datetime, calendar:universal_time(), Fields,
        #{})))))),
    data_to_fields(AppID, Parse, Vars, Data).

parse_rxq(Gateways, Fields, Vars) ->
    {_MAC, #rxq{freq=Freq, datr=Datr, codr=Codr}} = hd(Gateways),
    RxQ =
        lists:map(
            fun({MAC, #rxq{time=Time, rssi=RSSI, lsnr=SNR}}) ->
                #{mac=>MAC, rssi=>RSSI, lsnr=>SNR, time=>Time}
            end,
            Gateways),
    vars_add(freq, Freq, Fields,
        vars_add(datr, Datr, Fields,
        vars_add(codr, Codr, Fields,
        vars_add(best_gw, hd(RxQ), Fields,
        vars_add(all_gw, RxQ, Fields,
        Vars))))).

vars_add(_Field, undefined, _Fields, Vars) ->
    Vars;
vars_add(Field, Value, undefined, Vars) ->
    Vars#{Field => Value};
vars_add(Field, Value, Fields, Vars) ->
    case lists:member(atom_to_binary(Field, latin1), Fields) of
        true ->
            Vars#{Field => Value};
        false ->
            Vars
    end.

get_deveui(DevAddr) ->
    case mnesia:dirty_index_read(devices, DevAddr, #device.node) of
        [#device{deveui=DevEUI}|_] -> DevEUI;
        [] -> undefined
    end.

data_to_fields(AppId, {_, Fun}, Vars, Data) when is_function(Fun) ->
    try Fun(Vars, Data)
    catch
        Error:Term ->
            lorawan_utils:throw_error({handler, AppId}, {parse_failed, {Error, Term}}),
            Vars
    end;
data_to_fields(_AppId, _Else, Vars, _) ->
    Vars.


handle_downlink(AppId, Vars) ->
    [#handler{build=Build}] = mnesia:dirty_read(handlers, AppId),
    send_downlink(Vars,
        maps:get(time, Vars, undefined),
        #txdata{
            confirmed = maps:get(confirmed, Vars, false),
            port = maps:get(port, Vars, undefined),
            data = fields_to_data(AppId, Build, Vars),
            pending = maps:get(pending, Vars, undefined)
        }).

fields_to_data(AppId, {_, Fun}, Vars) when is_function(Fun) ->
    try Fun(Vars)
    catch
        Error:Term ->
            lorawan_utils:throw_error({handler, AppId}, {build_failed, {Error, Term}}),
            <<>>
    end;
fields_to_data(_AppId, _Else, Vars) ->
    maps:get(data, Vars, <<>>).

send_downlink(#{deveui := DevEUI}, undefined, TxData) ->
    case mnesia:dirty_read(devices, DevEUI) of
        [] ->
            {error, {{device, DevEUI}, unknown_deveui}};
        [Device] ->
            % standard downlink to an explicit node
            lorawan_application:store_frame(Device#device.node, TxData)
    end;
send_downlink(#{deveui := DevEUI}, Time, TxData) ->
    case mnesia:dirty_read(devices, DevEUI) of
        [] ->
            {error, {{device, DevEUI}, unknown_deveui}};
        [Device] ->
            [Node] = mnesia:dirty_read(nodes, Device#device.node),
            % class C downlink to an explicit node
            lorawan_handler:downlink(Node, Time, TxData)
    end;
send_downlink(#{devaddr := DevAddr}, undefined, TxData) ->
    case mnesia:dirty_read(nodes, DevAddr) of
        [] ->
            {error, {{node, DevAddr}, unknown_devaddr}};
        [_Node] ->
            % standard downlink to an explicit node
            lorawan_application:store_frame(DevAddr, TxData)
    end;
send_downlink(#{devaddr := DevAddr}, Time, TxData) ->
    case mnesia:dirty_read(nodes, DevAddr) of
        [] ->
            case mnesia:dirty_read(multicast_channels, DevAddr) of
                [] ->
                    {error, {{node, DevAddr}, unknown_devaddr}};
                [Group] ->
                    % scheduled multicast
                    lorawan_handler:multicast(Group, Time, TxData)
            end;
        [Node] ->
            % class C downlink to an explicit node
            lorawan_handler:downlink(Node, Time, TxData)
    end;
send_downlink(#{app := AppID}, undefined, TxData) ->
    % downlink to a group
    filter_group_responses(AppID,
        [lorawan_application:store_frame(DevAddr, TxData)
            || #node{devaddr=DevAddr} <- lorawan_backend_factory:nodes_with_backend(AppID)]
    );
send_downlink(#{app := AppID}, Time, TxData) ->
    % class C downlink to a group of devices
    filter_group_responses(AppID,
        [lorawan_handler:downlink(Node, Time, TxData)
            || Node <- lorawan_backend_factory:nodes_with_backend(AppID)]
    );
send_downlink(Else, _Time, _TxData) ->
    lager:error("Unknown downlink target: ~p", [Else]).

filter_group_responses(AppID, []) ->
    lager:warning("Group ~w is empty", [AppID]);
filter_group_responses(_AppID, List) ->
    lists:foldl(
        fun (ok, Right) -> Right;
            (Left, _) -> Left
        end,
        ok, List).

% end of file

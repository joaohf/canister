-module(canister).
-include("canister.hrl").
-include_lib("stdlib/include/qlc.hrl").
-export([
    start/0,
    clear/1,
    delete/1,
    get/2,
    put/3,
    touch/1,
    last_update_time/1,
    last_access_time/1,
    clear_untouched_sessions/0,
    delete_deleted_sessions/0
]).


init_tables() ->
    init_table(canister_data, record_info(fields, canister_data)),
    init_table(canister_times, record_info(fields, canister_times)).

init_table(Table, Fields) ->
    Res = mnesia:create_table(Table, [
        {disc_copies, [node()]},
        {attributes, Fields}
    ]),
    error_logger:info_msg("Initializing Canister Table: ~p: ~p",[Table, Res]),
    Res.

schema() ->
    case mnesia:create_schema([node()]) of
        ok -> ok;
        {error, {_, {already_exists, _}}} -> ok;
        Other -> exit({failed_to_init_schema, Other})
    end,
    mnesia:start().

start() ->
    schema(),
    init_tables().

maybe_wrap_transaction(Fun) ->
    case mnesia:is_transaction() of
        true ->
            Fun();
        false ->
            {atomic, Res} = mnesia:transaction(Fun),
            Res
    end.

write(Rec) ->
    case mnesia:is_transaction() of
        true -> mnesia:write(Rec);
        false -> mnesia:dirty_write(Rec)
    end.

read(Table, ID) ->
    Res = case mnesia:is_transaction() of
        true -> mnesia:read(Table, ID);
        false -> mnesia:dirty_read(Table, ID)
    end,
    case Res of
        [X] -> X;
        [] -> undefined
    end.

clear(ID) ->
    maybe_wrap_transaction(fun() ->
        case read(canister_data, ID) of
            #canister_data{} ->
                C = #canister_data{id=ID},
                write(C),
                update_delete_time(ID),
                queue_delete(ID),
                ok;
            _ ->
                ok
        end
    end).

delete(ID) ->
    maybe_wrap_transaction(fun() ->
        mnesia:delete(canister_data, ID),
        mnesia:delete(canister_times, ID)
    end).

    

data_get(Key, Data) ->
    case maps:find(Key, Data) of
        {ok, V} -> V;
        error -> undefined
    end.

get(ID, Key) ->
    case read(canister_data, ID) of
        #canister_data{data=Data} ->
            touch(Key),
            data_get(Key, Data);
        _ ->
            undefined
    end.
    
put(ID, Key, Value) ->
    maybe_wrap_transaction(fun() ->
        Rec = case read(canister_data, ID) of
            S = #canister_data{} ->
                S;
            _ ->
                #canister_data{id=ID}
        end,
        Data = Rec#canister_data.data,
        Prev = data_get(Key, Data),
        NewData = maps:put(Key, Value, Rec#canister_data.data),
        NewRec = Rec#canister_data{data=NewData},
        write(NewRec),
        update_update_time(ID),
        queue_update(ID),
        Prev
    end).

touch(ID) ->
    update_access_time(ID),
    queue_touch(ID).

queue_delete(ID) ->
    ok.

queue_update(ID) ->
    ok.

queue_touch(ID) ->
    ok.

resync(ID) ->
    ok.

update_update_time(ID) ->
    Now = os:timestamp(),
    Rec = #canister_times{
        id=ID,
        last_access=Now,
        last_update=Now
    },
    write(Rec).

update_delete_time(ID) ->
    Now = os:timestamp(),
    Rec = #canister_times{
        id=ID,
        last_access=undefined,
        last_update=undefined,
        deleted=Now
    },
    write(Rec).


last_access_time(ID) ->
    case read(canister_times, ID) of
        T = #canister_times{last_access=T} -> T;
        undefined -> undefined
    end.

last_update_time(ID) ->
    case read(canister_times, ID) of
        T = #canister_times{last_update=T} -> T;
        undefined -> undefined
    end.


update_access_time(ID) ->
    maybe_wrap_transaction(fun() ->
        case read(canister_times, ID) of
            T = #canister_times{} ->
                New = T#canister_times{last_access=os:timestamp()},
                write(New);
            undefined ->
                ok
        end
    end).
         
list_untouched_sessions() ->
    Timeout = session_timeout(),
    EffectiveTimeout = Timeout + 20, %% this just gives session management a little 60 minute buffer to be safe (basically to hopefully prevent losing data in the event of a netsplit)
    LastAccessedToExpire = qdate:to_now(qdate:add_minutes(-EffectiveTimeout)),
    Query = fun() ->
        qlc:eval(qlc:q(
            [{Rec#canister_times.id, Rec#canister_times.last_access} || Rec <- mnesia:table(canister_times),
                                             Rec#canister_times.last_access < LastAccessedToExpire]
        ))
    end,
    {atomic, Res} = mnesia:transaction(Query),
    Res.


clear_untouched_sessions() ->
    Sessions = list_untouched_sessions(),
    SessionsToSync = lists:filtermap(fun(Sess) ->
        case clear_untouched_session(Sess) of
            ok -> false;
            {resync, Node} -> {true, Sess, Node}
        end
    end, Sessions),
    lists:foreach(fun({ID, _}) ->
        resync(ID)
    end, SessionsToSync).


clear_untouched_session({ID, LastAccess}) ->
    case latest_cluster_access_time(ID, LastAccess) of
        ok ->
            clear(ID);
        {ok, LastAccess, Node} ->
            {resync, Node}
    end.

latest_cluster_access_time(ID, LastAccess) ->
    case nodes() of
        [] -> ok;
        Nodes ->
            case compare_latest_node_access_time(Nodes, ID, LastAccess) of
                undefined ->
                    ok;
                {Node, NewLastAccess} ->
                    {ok, NewLastAccess, Node}
            end
    end.

compare_latest_node_access_time(Nodes, ID, LastAccess) ->
    Me = node(),
    {FinalNode, FinalAccess} = lists:foldl(fun(Node, {BestNode, BestAccess}) ->
        NodeLatest = latest_node_access_time(Node, ID),
        case NodeLatest > BestAccess of
            true -> {Node, NodeLatest};
            false -> {BestNode, BestAccess}
        end
    end, {Me, LastAccess}, Nodes),

    case FinalNode of
        Me -> ok;
        _ ->
            {ok, FinalNode, FinalAccess}
    end.

%% If it takes longer than 2 seconds, that's a problem
-define(REMOTE_TIMEOUT, 2000).

latest_node_access_time(Node, ID) ->
    try erpc:call(Node, ?MODULE, last_access_time, [ID], ?REMOTE_TIMEOUT)
    catch _:_:_ -> 0
    end.


delete_deleted_sessions() ->
    %% This just makes sure we don't delete sessions that were incorrectly deleted during a netsplit event
    BeforeTime = qdate:to_now(qdate:add_minutes(-20)),
    Query = fun() ->
        Sessionids = qlc:eval(qlc:q(
            [Rec#canister_times.id || Rec <- mnesia:table(canister_times),
                                             Rec#canister_times.deleted=/=undefined,
                                             Rec#canister_times.deleted < BeforeTime]
        )),
        lists:foreach(fun(Sessid) ->
            delete(Sessid)
        end, Sessionids)
    end,
    {atomic, Res} = mnesia:transaction(Query),
    Res.

session_timeout() ->
    %% Because Nitrogen
    Apps = [canister, nitrogen_core, nitrogen],
    session_timeout(Apps).

session_timeout([]) ->
    20;
session_timeout([App|T]) ->
    case application:get_env(App, session_timeout) of
        X when is_integer(X) -> X;
        _ -> session_timeout(T)
    end.


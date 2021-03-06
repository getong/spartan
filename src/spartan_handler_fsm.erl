-module(spartan_handler_fsm).
-author("sdhillon").
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API

-define(SERVER, ?MODULE).

-define(TIMEOUT, 5000).

-include("spartan.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% State callbacks
-export([execute/2,
         wait_for_reply/2,
         waiting_for_rest_replies/2]).

%% Private utility functions
-export([resolve/3]).

%% API
-export([start/2]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-export_type([from/0]).

-type from() :: {module(), term()}.
-type outstanding_upstream() :: {upstream(), pid()}.

-record(state, {
    from = erlang:error() :: from(),
    dns_message :: dns:message() | undefined,
    data = erlang:error() :: binary(),
    outstanding_upstreams = [] :: [outstanding_upstream()],
    send_query_time :: integer(),
    start_timestamp = undefined :: os:timestamp()
}).

-spec(start(from(), binary() | dns:message()) -> {ok, pid()} | {error, overload}).
start(From, Data) ->
    case sidejob_supervisor:start_child(spartan_handler_fsm_sj,
                                        gen_fsm, start_link,
                                        [?MODULE, [From, Data], []]) of
        {error, overload} ->
            {error, overload};
        {ok, Pid} ->
            {ok, Pid}
    end.

%% @private
init([From, Data]) ->
    erlang:send_after(?TIMEOUT * 2, self(), timeout),
    process_flag(trap_exit, true),
    case From of
        {spartan_tcp_handler, Pid} when is_pid(Pid) ->
            %% Link handler pid.
            erlang:link(Pid);
        _ ->
            %% Don't link.
            ok
    end,
    %% Set send query time to avoid typespec issues. This also requires that we don't make any blocking calls
    %% between now, and execute. This is also okay, because timeout = 0, so we should immediately transition
    %% to execute
    Now = erlang:monotonic_time(),
    {ok, execute, #state{from=From, data=Data, send_query_time = Now}, 0}.

%% @private
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%% @private
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%% @private
handle_info(timeout, wait_for_reply, State) ->
    reply_fail(State),
    mark_rest_as_failed(State),
    {stop, normal, State};
handle_info(timeout, waiting_for_rest_replies, State) ->
    mark_rest_as_failed(State),
    {stop, normal, State};
handle_info({'DOWN', _MonRef, process, _Pid, normal}, StateName, State) ->
    {next_state, StateName, State};
handle_info({'DOWN', _MonRef, process, Pid, Reason}, StateName,
            #state{outstanding_upstreams=OutstandingUpstreams0}=State) ->
    OutstandingUpstreams =
        case lists:keyfind(Pid, 2, OutstandingUpstreams0) of
            false ->
                lager:warning("Error, unrecognized late response, reason: ~p", [Reason]),
                OutstandingUpstreams0;
            {Upstream, _Pid} ->
                spartan_metrics:update([?MODULE, Upstream, failures], 1, ?SPIRAL),
                lists:keydelete(Upstream, 1, OutstandingUpstreams0)
        end,
    {next_state, StateName, State#state{outstanding_upstreams=OutstandingUpstreams}, ?TIMEOUT};
handle_info(Info, StateName, State) ->
    lager:debug("Got info: ~p", [Info]),
    {next_state, StateName, State, ?TIMEOUT}.

%% @private
terminate(_Reason, _StateName, _State) ->
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

execute(timeout, State = #state{data = Data}) ->
    %% The purpose of this pattern match is to bail as soon as possible,
    %% in case the data we've received is 'corrupt'
    DNSMessage = #dns_message{} = dns:decode_message(Data),
    Questions = DNSMessage#dns_message.questions,
    State1 = State#state{dns_message = DNSMessage},
    case spartan_router:upstreams_from_questions(Questions) of
        [] ->
            spartan_metrics:update([?APP, no_upstreams_available], 1, ?SPIRAL),
            reply_fail(State1),
            {stop, normal, State};
        Upstreams ->
            StartTimestamp = os:timestamp(),
            OutstandingUpstreams = start_workers(Upstreams, State),
            State2 = State1#state{start_timestamp=StartTimestamp,
                                  outstanding_upstreams=OutstandingUpstreams},
            {next_state, wait_for_reply, State2, ?TIMEOUT}
    end.

%% The first reply.
wait_for_reply({upstream_reply, Upstream, ReplyData},
               #state{start_timestamp=StartTimestamp}=State) ->
    %% Match to force quick failure.
    #dns_message{} = dns:decode_message(ReplyData),

    %% Reply immediately.
    reply_success(ReplyData, State),

    %% Then, record latency metrics after response.
    Timestamp = os:timestamp(),
    TimeDiff = timer:now_diff(Timestamp, StartTimestamp),
    spartan_metrics:update([?MODULE, Upstream, latency], TimeDiff, ?HISTOGRAM),

    maybe_done(Upstream, State);
%% Timeout waiting for messages, assume all upstreams have timed out.
wait_for_reply(timeout, State) ->
    reply_fail(State),
    spartan_metrics:update([?APP, upstreams_failed], 1, ?SPIRAL),
    mark_rest_as_failed(State),
    {stop, normal, State}.

waiting_for_rest_replies({upstream_reply, Upstream, _ReplyData},
                         #state{start_timestamp=StartTimestamp}=State) ->
    %% Record latency metrics after response.
    Timestamp = os:timestamp(),
    TimeDiff = timer:now_diff(Timestamp, StartTimestamp),
    spartan_metrics:update([?MODULE, Upstream, latency], TimeDiff, ?HISTOGRAM),

    %% Ignore reply data.
    maybe_done(Upstream, State);
waiting_for_rest_replies(timeout,
                         #state{outstanding_upstreams=Upstreams}=State) ->
    lists:foreach(fun({Upstream, _Pid}) ->
                        spartan_metrics:update([?MODULE, Upstream, failures], 1, ?SPIRAL)
                  end, Upstreams),
    {stop, normal, State}.


%% Internal API
%% Kind of ghetto. Fix it.
%% @private
maybe_done(Upstream, #state{outstanding_upstreams=OutstandingUpstreams0}=State) ->

    spartan_metrics:update([?MODULE, Upstream, successes], 1, ?SPIRAL),
    Now = erlang:monotonic_time(),
    OutstandingUpstreams = lists:keydelete(Upstream, 1, OutstandingUpstreams0),
    State1 = State#state{outstanding_upstreams=OutstandingUpstreams},
    case OutstandingUpstreams of
        [] ->
            %% We're done. Great.
            {stop, normal, State1};
        _ ->
            Timeout = erlang:convert_time_unit(Now - State#state.send_query_time, native, milli_seconds),
            {next_state, waiting_for_rest_replies, State1, Timeout}
    end.

%% @private
reply_success(Data, _State = #state{from = {FromModule, FromKey}}) ->
    spartan_metrics:update([FromModule, successes], 1, ?COUNTER),
    FromModule:do_reply(FromKey, Data).

%% @private
reply_fail(_State1 = #state{dns_message = DNSMessage, from = {FromModule, FromKey}}) ->
    spartan_metrics:update([FromModule, failures], 1, ?COUNTER),
    Reply =
        DNSMessage#dns_message{
            rc = ?DNS_RCODE_SERVFAIL
        },
    EncodedReply = dns:encode_message(Reply),
    FromModule:do_reply(FromKey, EncodedReply).

%% @private
resolve(Parent, Upstream, State) ->
    try
        do_resolve(Parent, Upstream, State)
    catch
        Class:Reason ->
            StackTrace = erlang:get_stacktrace(),
            lager:warning("Resolver (~p) Process exited: ~p stacktrace ~p",
                [Upstream, Reason, erlang:get_stacktrace()]),
            erlang:raise(Class, Reason, StackTrace)
    end.

do_resolve(Parent, Upstream = {UpstreamIP, UpstreamPort}, #state{data = Data, from = {spartan_udp_server, _}}) ->
    {ok, Socket} = gen_udp:open(0, [{reuseaddr, true}, {active, once}, binary]),
    gen_udp:send(Socket, UpstreamIP, UpstreamPort, Data),
    MonRef = erlang:monitor(process, Parent),
    try
        receive
            {'DOWN', MonRef, process, _Pid, Reason} ->
                exit(Reason);
            {udp, Socket, UpstreamIP, UpstreamPort, ReplyData} ->
                gen_fsm:send_event(Parent, {upstream_reply, Upstream, ReplyData})
        after ?TIMEOUT ->
            ok
        end
    after
        gen_udp:close(Socket)
    end;

%% @private
do_resolve(Parent, Upstream = {UpstreamIP, UpstreamPort}, #state{data = Data, from = {spartan_tcp_handler, _}}) ->
    TCPOptions = [{active, once}, binary, {packet, 2}, {send_timeout, 1000}],
    {ok, Socket} = gen_tcp:connect(UpstreamIP, UpstreamPort, TCPOptions, ?TIMEOUT),
    ok = gen_tcp:send(Socket, Data),
    MonRef = erlang:monitor(process, Parent),
    try
        receive
            {'DOWN', MonRef, process, _Pid, Reason} ->
                exit(Reason);
            {tcp, Socket, ReplyData} ->
                gen_fsm:send_event(Parent, {upstream_reply, Upstream, ReplyData});
            {tcp_closed, Socket} ->
                exit(closed);
            {tcp_error, Socket, Reason} ->
                exit(Reason)
        after ?TIMEOUT ->
            ok
        end
    after
        gen_tcp:close(Socket)
    end.

%% @private
take_upstreams(Upstreams0) when length(Upstreams0) < 2 -> %% 0, 1 or 2 Upstreams
    Upstreams0;
take_upstreams(Upstreams0) ->
    ClassifiedUpstreams = lists:map(fun(Upstream) -> {classify_upstream(Upstream), [Upstream]} end, Upstreams0),
    Buckets0 = lists:foldl(
        fun({Bucket, Upstreams}, BucketedUpstreamAcc) ->
            orddict:append_list(Bucket, Upstreams, BucketedUpstreamAcc)
        end,
        orddict:new(), ClassifiedUpstreams),
    %% This gives us the first two buckets of upstreams
    %% We know there will be at least two Upstreams in it
    {_Buckets, UpstreamBuckets} = lists:unzip(Buckets0),
    case UpstreamBuckets of
        [Bucket0] ->
            choose2(Bucket0);
        [Bucket0|_] when length(Bucket0) > 2 ->
            choose2(Bucket0);
        [Bucket0, Bucket1|_] ->
            choose2(Bucket0 ++ Bucket1)
    end.

%% @private
choose2(List) ->
    Length = length(List),
    case Length > 2 of
        true ->
            %% This could result in querying duplicate upstreams :(
            {Idx0, Idx1} = maybe_two_uniq_rand(Length, 10),
            [lists:nth(Idx0, List), lists:nth(Idx1, List)];
        false ->
            List
    end.

%% @private
maybe_two_uniq_rand(Max, 0) ->
    Rand0 = rand:uniform(Max),
    Rand1 = rand:uniform(Max),
    {Rand0, Rand1};
maybe_two_uniq_rand(Max, MaxTries) ->
    Rand0 = rand:uniform(Max),
    Rand1 = rand:uniform(Max),
    case Rand0 == Rand1 of
        true ->
            maybe_two_uniq_rand(Max, MaxTries - 1);
        false ->
            {Rand0, Rand1}
    end.


%% @private
-spec(classify_upstream(Upstream :: inet:ip4_address()) -> non_neg_integer()).
classify_upstream(Upstream) ->
    case exometer:get_value([?MODULE, Upstream, failures]) of
        {error, _} -> %% If we've never seen it before, assume it never failed
            0;
        {ok, Metric} ->
            {one, Failures} = lists:keyfind(one, 1, Metric),
            Failures
    end.

%% @private
mark_rest_as_failed(#state{outstanding_upstreams=Upstreams}) ->
    mark_rest_as_failed(Upstreams);
mark_rest_as_failed(Upstreams) ->
    lists:foreach(fun({Upstream, _Pid}) ->
        spartan_metrics:update([?MODULE, Upstream, failures], 1, ?SPIRAL)
                  end, Upstreams).

start_workers([Upstream], State) ->
    _ = resolve(self(), Upstream, State),
    [{Upstream, self()}];
start_workers(Upstreams, State) ->
    QueryUpstreams = take_upstreams(Upstreams),
    lists:map(fun (Upstream) ->
        Pid =
            proc_lib:spawn(
                ?MODULE, resolve,
                [self(), Upstream, State]
            ),
        erlang:monitor(process, Pid),
        {Upstream, Pid}
    end, QueryUpstreams).

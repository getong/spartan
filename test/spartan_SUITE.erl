-module(spartan_SUITE).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

%% common_test callbacks
-export([%% suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0]).

%% tests
-export([
         overload_test/1,
         multiple_query_test/1,
         upstream_test/1,
         mesos_test/1,
         zk_test/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").


-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-define(CONFIG, "../../../../config/sys.config").

%% ===================================================================
%% common_test callbacks
%% ===================================================================

init_per_suite(_Config) ->
    application:load(erldns),
    {ok, [Terms]} = file:consult(?CONFIG),
    lists:foreach(fun({App, Environment}) ->
                        lists:foreach(fun({Par, Val}) ->
                                            ok = application:set_env(App, Par, Val)
                        end, Environment)
                  end, Terms),
    ok = application:set_env(spartan, handler_limit, 16),
    ok = application:set_env(spartan, mesos_resolvers, [{{127, 0, 0, 1}, 62053}]),
    {ok, _} = application:ensure_all_started(spartan),
    generate_fixture_mesos_zone(),
    _Config.

end_per_suite(_Config) ->
    _Config.

init_per_testcase(_Case, _Config) ->
    _Config.

end_per_testcase(_, _Config) ->
    ok.

all() ->
    [
     upstream_test,
     mesos_test,
     zk_test,
     multiple_query_test,
     overload_test
    ].

generate_fixture_mesos_zone() ->
    Records = [
        #dns_rr{
            name = <<"mesos">>,
            type = ?DNS_TYPE_SOA,
            ttl = 5,
            data = #dns_rrdata_soa{
                mname = <<"ns.spartan">>, %% Nameserver
                rname = <<"support.mesosphere.com">>,
                serial = 0,
                refresh = 60,
                retry = 180,
                expire = 86400,
                minimum = 1
            }
        },
        #dns_rr{
            name = <<"master.mesos">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
        },
        #dns_rr{
            name = <<"spartan">>,
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = <<"ns.spartan">>
            }
        }
    ],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    ok = erldns_zone_cache:put_zone({<<"mesos">>, Sha, Records}).

%% ===================================================================
%% tests
%% ===================================================================

%% @doc Assert an upstream request is resolved by the dual dispatch FSM.
upstream_test(_Config) ->
    {ok, DnsMsg} = inet_res:resolve("www.google.com", in, a, resolver_options()),
    Answers = inet_dns:msg(DnsMsg, anlist),
    ?assert(length(Answers) > 0),
    ok.

%% @doc Assert we can resolve Mesos records.
%%
%%      Shallow test; verifies that the mesos domain is parsed correctly
%%      and send to the dual dispatch FSM, but actual
%%      resolution bypasses the mesos servers, since they won't be
%%      there.  The external resolution test is covered via
%%      upstream_test/1.
%%
mesos_test(_Config) ->
    {ok, DnsMsg} = inet_res:resolve("master.mesos", in, a, resolver_options()),
    [Answer] = inet_dns:msg(DnsMsg, anlist),
    Data = inet_dns:rr(Answer, data),
    ?assertMatch({127, 0, 0, 1}, Data),
    ok.

%% @doc Assert we can resolve the Zookeeper records.
zk_test(_Config) ->
    gen_server:call(spartan_zk_record_server, refresh),
    {ok, DnsMsg} = inet_res:resolve("zk-1.zk", in, a, resolver_options()),
    [Answer] = inet_dns:msg(DnsMsg, anlist),
    Data = inet_dns:rr(Answer, data),
    ?assertMatch({127, 0, 0, 1}, Data),
    ok.

multiple_query_test(_Config) ->
    Expected = "1.1.1.1\n2.2.2.2\n127.0.0.1\n",
    Command = "dig -p 8053 @127.0.0.1 +keepopen +tcp +short spartan1.testing.express spartan2.testing.express master.mesos",
    ?assertCmdOutput(Expected, Command).

overload_test(_Config) ->
    try
        ok = meck:new(spartan_udp_server, [unstick, passthrough]),
        ok = meck:expect(
                spartan_udp_server, do_reply,
                fun (_From = {Pid, {IP, Port}}, Data) ->
                    timer:sleep(500),
                    % meck:passthrough([From, Data])
                    gen_server:cast(Pid, {send_behalf, IP, Port, Data})
                end),
        Parent = self(),
        Pids = lists:map(fun (_) ->
            proc_lib:spawn_link(fun () ->
                Host = "master.mesos",
                Opts = resolver_options(),
                Result =
                    case inet_res:resolve(Host, in, a, Opts, 700) of
                        {ok, _} -> ok;
                        {error, timeout} -> timeout
                    end,
                Parent ! {done, self(), Result}
            end)
        end, lists:seq(0, 32)),
        Results = lists:map(fun (Pid) ->
            receive
                {done, Pid, Result} ->
                    Result
            after
                1000 ->
                    throw(timeout)
            end
        end, Pids),
        ?assertMatch([ok, timeout], lists:usort(Results))
    after
        ok = meck:unload(spartan_udp_server)
    end.

%% @private
%% @doc Use the Spartan resolver.
resolver_options() ->
    LocalResolver = "127.0.0.1:8053",
    [{nameservers, [spartan_app:parse_ipv4_address_with_port(LocalResolver, 53)]}].

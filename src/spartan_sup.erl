-module(spartan_sup).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-include("spartan.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    ZkRecordServer = {spartan_zk_record_server,
                      {spartan_zk_record_server, start_link, []},
                       permanent, 5000, worker,
                       [spartan_zk_record_server]},
    ConfigLoaderServer =
        #{
            id => spartan_config_loader_server,
            start => {spartan_config_loader_server, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [spartan_config_loader_server]
        },

    WatchdogSup = #{
        id => spartan_watchdog,
        start => {spartan_watchdog, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [spartan_watchdog]
    },
    %% Configure metrics.
    spartan_metrics:setup(),

    %% Setup ready.spartan zone / record
    ok = spartan_zone_setup(),
    ok = localhost_zone_setup(),

    %% Systemd Sup intentionally goes last
    Children = [ZkRecordServer, ConfigLoaderServer, WatchdogSup],
    Children1 = maybe_add_udp_servers(Children),

    sidejob:new_resource(
        spartan_handler_fsm_sj, sidejob_supervisor,
        spartan_config:handler_limit()),

    %% The top level sup should never die.
    {ok, { {one_for_all, 10000, 1}, Children1} }.

%%====================================================================
%% Internal functions
%%====================================================================


%% @private
maybe_add_udp_servers(Children) ->
    case spartan_config:udp_enabled() of
        true ->
            udp_servers() ++ Children;
        false ->
            Children
    end.

udp_servers() ->
    Addresses = spartan_config:bind_ips(),
    lists:map(fun udp_server/1, Addresses).



udp_server(Address) ->
    #{
        id => {spartan_udp_server, Address},
        start => {spartan_udp_server, start_link, [Address]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [spartan_udp_server]
    }.


localhost_zone_setup() ->
    Records = [
        #dns_rr{
            name = <<"localhost">>,
            type = ?DNS_TYPE_SOA,
            ttl = 5,
            data = #dns_rrdata_soa{
                mname = <<"ns.spartan">>, %% Nameserver
                rname = <<"support.mesosphere.com">>,
                serial = 1,
                refresh = 60,
                retry = 180,
                expire = 86400,
                minimum = 1
            }
        },
        #dns_rr{
            name = <<"localhost">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
        },
        #dns_rr{
            name = <<"localhost">>,
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = <<"ns.spartan">>
            }
        }
    ],
    Sha = crypto:hash(sha, term_to_binary(Records)),
    case catch erldns_zone_cache:put_zone({<<"localhost">>, Sha, Records}) of
        ok ->
            ok;
        Else ->
            {error, Else}
    end.

spartan_zone_setup() ->
    Records = [
        #dns_rr{
            name = <<"spartan">>,
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
            name = <<"ready.spartan">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{ip = {127, 0, 0, 1}}
        },
        #dns_rr{
            name = <<"ns.spartan">>,
            type = ?DNS_TYPE_A,
            ttl = 5,
            data = #dns_rrdata_a{
                ip = {198, 51, 100, 1} %% Default Spartan IP
            }
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
    case catch erldns_zone_cache:put_zone({<<"spartan">>, Sha, Records}) of
        ok ->
            ok;
        Else ->
            {error, Else}
    end.

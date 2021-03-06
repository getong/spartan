-module(spartan_router).
-author("sdhillon").

-include("spartan.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% API
-export([upstreams_from_questions/1]).

%% @doc Resolvers based on a set of "questions"
-spec(upstreams_from_questions(dns:questions()) -> ordsets:ordset(upstream())).
upstreams_from_questions([#dns_query{name=Name}]) ->
    Labels = spartan_app:parse_upstream_name(Name),
    Upstreams = find_upstream(Name, Labels),
    lists:map(fun validate_upstream/1, Upstreams);

%% There is more than one question. This is beyond our capabilities at the moment
upstreams_from_questions([Question|Others]) ->
    spartan_metrics:update([spartan, ignored_questions], length(Others), ?COUNTER),
    upstreams_from_questions([Question]).

-spec(validate_upstream(upstream()) -> upstream()).
validate_upstream({{_, _, _, _}, Port} = Upstream) when is_integer(Port) ->
    Upstream.

%% @private
-spec(mesos_resolvers() -> [upstream()]).
mesos_resolvers() ->
    application:get_env(?APP, mesos_resolvers, []).

%% This one is a little bit more complicated...
%% @private
-spec(erldns_resolvers() -> [upstream()]).
erldns_resolvers() ->
    ErlDNSServers = application:get_env(erldns, servers, []),
    retrieve_servers(ErlDNSServers, []).
retrieve_servers([], Acc) ->
    Acc;
retrieve_servers([Config|Rest], Acc) ->
    case {
            inet:parse_ipv4_address(proplists:get_value(address, Config, "")),
            proplists:get_value(port, Config),
            proplists:get_value(family, Config)
    } of
        {_, undefined, _} ->
            retrieve_servers(Rest, Acc);
        {{ok, Address}, Port, inet} when is_integer(Port) ->
            retrieve_servers(Rest, [{Address, Port}|Acc]);
        _ ->
            retrieve_servers(Rest, Acc)
    end.

%% @private
-spec(default_resolvers() -> [upstream()]).
default_resolvers() ->
    Defaults = [{{8, 8, 8, 8}, 53},
                {{4, 2, 2, 1}, 53},
                {{8, 8, 8, 8}, 53},
                {{4, 2, 2, 1}, 53},
                {{8, 8, 8, 8}, 53}],
    application:get_env(?APP, upstream_resolvers, Defaults).

%% @private
-spec(find_upstream(Name :: binary(), Labels :: [binary()]) -> [upstream()]).
find_upstream(_Name, [<<"mesos">>|_]) ->
    mesos_resolvers();
find_upstream(_Name, [<<"zk">>|_]) ->
    erldns_resolvers();
find_upstream(_Name, [<<"spartan">>|_]) ->
    erldns_resolvers();
find_upstream(Name, Labels) ->
    case find_custom_upstream(Labels) of
        [] ->
            find_default_upstream(Name);
        Resolvers ->
            lager:debug("resolving ~p with custom upstream: ~p", [Labels, Resolvers]),
            Resolvers
    end.

-spec(find_custom_upstream(Labels :: [binary()]) -> [upstream()]).
find_custom_upstream(QueryLabels) ->
    ForwardZones = spartan_config:forward_zones(),
    UpstreamFilter = upstream_filter_fun(QueryLabels),
    maps:fold(UpstreamFilter, [], ForwardZones).

-spec(upstream_filter_fun([dns:labels()]) ->
    fun(([dns:labels()], upstream(), [upstream()]) -> [upstream()])).
upstream_filter_fun(QueryLabels) ->
    fun(Labels, Upstream, Acc) ->
        case lists:prefix(Labels, QueryLabels) of
            true ->
                Upstream;
            false ->
                Acc
        end
    end.

-spec(find_default_upstream(Name :: binary()) -> [upstream()]).
find_default_upstream(Name) ->
    case erldns_zone_cache:get_authority(Name) of
        {ok, _} ->
            erldns_resolvers();
        _ ->
            default_resolvers()
    end.

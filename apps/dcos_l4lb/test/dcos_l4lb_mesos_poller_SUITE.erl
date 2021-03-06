-module(dcos_l4lb_mesos_poller_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include("dcos_l4lb.hrl").

-export([
    all/0,
    init_per_suite/1, end_per_suite/1,
    init_per_testcase/2, end_per_testcase/2
]).

-export([
    test_lashup/1,
    test_app_restart/1
]).


%% root tests
all() -> [
    test_lashup,
    test_app_restart
].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_, Config) ->
    meck:new(dcos_net_dist, [no_link, passthrough]),
    meck:expect(dcos_net_dist, nodeip, fun () -> node_ip() end),
    meck:new(dcos_net_mesos_listener, [no_link, passthrough]),
    Config.

end_per_testcase(_, _Config) ->
    [ begin
        ok = application:stop(App),
        ok = application:unload(App)
    end || {App, _, _} <- application:which_applications(),
    not lists:member(App, [stdlib, kernel]) ],
    os:cmd("rm -rf Mnesia.*"),
    meck:unload(dcos_net_mesos_listener),
    meck:unload(dcos_net_dist),
    dcos_l4lb_ipset_mgr:cleanup(),
    ok.

node_ip() ->
    {10, 0, 0, 243}.

ensure_l4lb_started() ->
    {ok, _} = application:ensure_all_started(dcos_l4lb),
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, []}),
    meck:wait(dcos_net_mesos_listener, poll, '_', 5000),
    timer:sleep(100).

meck_mesos_poll_no_tasks() ->
    {ok, #{}}.

meck_mesos_poll_app_task() ->
    {ok, #{
        <<"app.6e53a5c1-1f27-11e6-bc04-4e40412869d8">> => #{
            name => <<"app">>,
            runtime => mesos,
            framework => <<"marathon">>,
            agent_ip => node_ip(),
            task_ip => [{9, 0, 1, 29}],
            ports => [
                #{name => <<"http">>, protocol => tcp, host_port => 12049,
                  port => 80, vip => [<<"merp:5000">>]}
            ],
            state => running
        }
    }}.

meck_mesos_poll_app_task_after_restart() ->
    {ok, #{
        <<"app.b35733e8-8336-4d21-ae60-f3bc4384a93a">> => #{
            name => <<"app">>,
            runtime => mesos,
            framework => <<"marathon">>,
            agent_ip => node_ip(),
            task_ip => [{9, 0, 1, 30}],
            ports => [
                #{name => <<"http">>, protocol => tcp, host_port => 23176,
                  port => 80, vip => [<<"merp:5000">>]}
            ],
            state => running
        }
    }}.

test_lashup(_Config) ->
    meck:expect(dcos_net_mesos_listener, poll, fun meck_mesos_poll_app_task/0),
    ensure_l4lb_started(),
    Actual = lashup_kv:value(?VIPS_KEY2),
    ?assertMatch(
        [{_, [{{10, 0, 0, 243}, {{10, 0, 0, 243}, 12049}}]}],
        Actual).

test_app_restart(_Config) ->
    meck:expect(dcos_net_mesos_listener, poll, fun meck_mesos_poll_app_task/0),
    ensure_l4lb_started(),
    ActualVIPs = retrieve_data(),
    ?assertMatch([{_, [{{10, 0, 0, 243}, {{10, 0, 0, 243}, 12049}}]}],
        ActualVIPs),

    meck:expect(dcos_net_mesos_listener, poll, fun meck_mesos_poll_no_tasks/0),
    ActualVIPs2 = retrieve_data(),
    ?assertMatch([], ActualVIPs2),

    meck:expect(dcos_net_mesos_listener, poll,
        fun meck_mesos_poll_app_task_after_restart/0),
    ActualVIPs3 = retrieve_data(),
    ?assertMatch([{_, [{{10, 0, 0, 243}, {{10, 0, 0, 243}, 23176}}]}],
        ActualVIPs3).

retrieve_data() ->
    meck:reset(dcos_net_mesos_listener),
    meck:wait(dcos_net_mesos_listener, poll, '_', 5000),
    timer:sleep(100),
    lashup_kv:value(?VIPS_KEY2).

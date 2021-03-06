%% Basic utility module to integrate with systemd sd_notify via shell commands

-module(spartan_watchdog).
-author("Sargun Dhillon <sargun@mesosphere.com>").
-behaviour(gen_server).


%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

%% API
-export([start_link/0]).

-include("spartan.hrl").

-define(REFRESH_INTERVAL, 15000).
-define(REFRESH_MESSAGE,  refresh).


-define(PF_LOCAL, 1).
-define(UNIX_PATH_MAX, 108).

%% State record.
-record(state, {kill_timer}).

%%%===================================================================
%%% API
%%%===================================================================


%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @private
-spec init([]) -> {ok, #state{}}.
init([]) ->
    {ok, _} = timer:send_after(?REFRESH_INTERVAL, ?REFRESH_MESSAGE),
    Timer = schedule_kill(),
    {ok, #state{kill_timer = Timer}}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.

%% @private
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(?REFRESH_MESSAGE, State = #state{kill_timer = KillTimer}) ->
    lager:debug("Waking up watchdog"),
    {ok, Timer1} = timer:kill_after(?REFRESH_INTERVAL * 4),
    ok = healthcheck(),
    timer:cancel(Timer1),
    {ok, _} = timer:send_after(?REFRESH_INTERVAL, ?REFRESH_MESSAGE),
    timer:cancel(KillTimer),
    {noreply, State#state{kill_timer = schedule_kill()}};
handle_info(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

schedule_kill() ->
    KillCmd = lists:flatten(io_lib:format("kill -9 ~s", [os:getpid()])),
    {ok, Timer} = timer:apply_after(?REFRESH_INTERVAL * 2, os, cmd, [KillCmd]),
    Timer.

healthcheck() ->
    ok = maybe_udp_healthcheck(),
    ok = maybe_tcp_healthcheck(),
    ok.

maybe_tcp_healthcheck() ->
    case spartan_config:tcp_enabled() of
        true ->
            ok = run_healthchecks(fun tcp_healthcheck/0, 5);
        _ ->
            ok
    end.

maybe_udp_healthcheck() ->
    case application:get_env(?APP, udp_server_enabled, true) of
        true ->
            ok = run_healthchecks(fun udp_healthcheck/0, 5);
        _ ->
            ok
    end.

run_healthchecks(_HealthFun, 0) ->
    false;
run_healthchecks(HealthFun, N) ->
    case HealthFun() of
        true ->
            ok;
        false ->
            lager:warning("Healthcheck ~p failed", [HealthFun]),
            run_healthchecks(HealthFun, N - 1)
    end.

tcp_healthcheck() ->
    TCPPort = spartan_config:tcp_port(),
    HealthcheckIP = healthcheck_ip(),
    DNSOpts = [
        {nameservers, [{HealthcheckIP, TCPPort}]},
        {timeout, 5000},
        {usevc, true}
    ],
    [{127, 0, 0, 1}] == inet_res:lookup("ready.spartan", in, a, DNSOpts).


udp_healthcheck() ->
    UDPPort = spartan_config:udp_port(),
    HealthcheckIP = healthcheck_ip(),
    DNSOpts = [
        {nameservers, [{HealthcheckIP, UDPPort}]},
        {timeout, 5000},
        {usevc, false}
    ],
    [{127, 0, 0, 1}] == inet_res:lookup("ready.spartan", in, a, DNSOpts).

healthcheck_ip() ->
    BindIPs = spartan_config:bind_ips(),
    N = rand:uniform(length(BindIPs)),
    lists:nth(N, BindIPs).

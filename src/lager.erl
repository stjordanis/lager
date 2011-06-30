%% Copyright (c) 2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

-module(lager).

-behaviour(gen_server).

%% API
-export([start_link/0, start/0,
        log/7, log/8, log/3, log/4,
        get_loglevel/1, set_loglevel/2, set_loglevel/3]).

%% callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {event_pid, handler_loglevels, error_logger_handlers}).

%% API

start_link() ->
    Handlers = case application:get_env(lager, handlers) of
        undefined ->
            [{lager_console_backend, [info]},
                {lager_file_backend, [{"log/error.log", error}, {"log/console.log", info}]}];
        {ok, Val} ->
            Val
    end,
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Handlers], []).

start() ->
    Handlers = case application:get_env(lager, handlers) of
        undefined ->
            [{lager_console_backend, [info]},
                {lager_file_backend, [{"log/error.log", error}, {"log/console.log", info}]}];
        {ok, Val} ->
            Val
    end,
    gen_server:start({local, ?MODULE}, ?MODULE, [Handlers], []).

log(Level, Module, Function, Line, Pid, Time, Message) ->
    Timestamp = lager_util:format_time(Time),
    Msg = [io_lib:format("[~p] ~p@~p:~p:~p ", [Level, Pid, Module,
                Function, Line]),  Message],
    gen_event:sync_notify(lager_event, {log, lager_util:level_to_num(Level),
            Timestamp, Msg}).

log(Level, Module, Function, Line, Pid, Time, Format, Args) ->
    Timestamp = lager_util:format_time(Time),
    Msg = [io_lib:format("[~p] ~p@~p:~p:~p ", [Level, Pid, Module,
                Function, Line]), io_lib:format(Format, Args)],
    gen_event:sync_notify(lager_event, {log, lager_util:level_to_num(Level),
            Timestamp, Msg}).

log(Level, Pid, Message) ->
    Timestamp = lager_util:format_time(),
    Msg = [io_lib:format("[~p] ~p ", [Level, Pid]), Message],
    gen_event:sync_notify(lager_event, {log, lager_util:level_to_num(Level),
            Timestamp, Msg}).

log(Level, Pid, Format, Args) ->
    Timestamp = lager_util:format_time(),
    Msg = [io_lib:format("[~p] ~p ", [Level, Pid]), io_lib:format(Format, Args)],
    gen_event:sync_notify(lager_event, {log, lager_util:level_to_num(Level),
            Timestamp, Msg}).

set_loglevel(Handler, Level) when is_atom(Level) ->
    gen_server:call(?MODULE, {set_loglevel, Handler, Level}).

set_loglevel(Handler, Ident, Level) when is_atom(Level) ->
    gen_server:call(?MODULE, {set_loglevel, Handler, Ident, Level}).

get_loglevel(Handler) ->
    case gen_server:call(?MODULE, {get_loglevel, Handler}) of
        X when is_integer(X) ->
            lager_util:num_to_level(X);
        Y -> Y
    end.

%% gen_server callbacks

init([Handlers]) ->
    %% start a gen_event linked to this process
    gen_event:start_link({local, lager_event}),
    %% spin up all the defined handlers
    [gen_event:add_sup_handler(lager_event, Module, Args) || {Module, Args} <- Handlers],
    MinLog = minimum_log_level(get_log_levels()),
    lager_mochiglobal:put(loglevel, MinLog),
    case application:get_env(lager, error_logger_redirect) of
        {ok, false} ->
            {ok, #state{}};
        _ ->
            gen_event:add_sup_handler(error_logger, error_logger_lager_h, []),
            %% TODO allow user to whitelist handlers to not be removed
            [gen_event:delete_handler(error_logger, X, {stop_please, ?MODULE}) ||
                X <- gen_event:which_handlers(error_logger) -- [error_logger_lager_h]],
            {ok, #state{}}
    end.

handle_call({set_loglevel, Handler, Level}, _From, State) ->
    Reply = gen_event:call(lager_event, Handler, {set_loglevel, Level}),
    %% recalculate min log level
    MinLog = minimum_log_level(get_log_levels()),
    lager_mochiglobal:put(loglevel, MinLog),
    {reply, Reply, State};
handle_call({set_loglevel, Handler, Ident, Level}, _From, State) ->
    Reply = gen_event:call(lager_event, Handler, {set_loglevel, Ident, Level}),
    %% recalculate min log level
    MinLog = minimum_log_level(get_log_levels()),
    lager_mochiglobal:put(loglevel, MinLog),
    {reply, Reply, State};
handle_call({get_loglevel, Handler}, _From, State) ->
    Reply = gen_event:call(lager_event, Handler, get_loglevel),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({gen_event_EXIT, error_logger_lager_h, {'EXIT', Reason}}, State) ->
    lager:log(error, self(), ["Restarting lager error handler after it exited with ",
            error_logger_lager_h:format_reason(Reason)]),
    gen_event:add_sup_handler(error_logger, error_logger_lager_h, []),
    {noreply, State};
handle_info(Info, State) ->
    io:format("got info ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    gen_event:stop(lager_event),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal functions

get_log_levels() ->
    [gen_event:call(lager_event, Handler, get_loglevel) ||
        Handler <- gen_event:which_handlers(lager_event)].

minimum_log_level([]) ->
    9; %% higher than any log level, logging off
minimum_log_level(Levels) ->
    erlang:hd(lists:sort(Levels)).

%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% Internal ACL that load rules from etc/acl.config
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqttd_acl_internal).

-author('feng@emqtt.io').

-include("emqttd.hrl").

-export([all_rules/0]).

-behaviour(emqttd_acl).

%% ACL callbacks
-export([init/1, check_acl/2, reload_acl/1, description/0]).

-define(ACL_RULE_TABLE, mqtt_acl_rule).

-record(state, {acl_file, nomatch = allow}).

%%%=============================================================================
%%% API
%%%=============================================================================

%% @doc Read all rules.
-spec all_rules() -> list(emqttd_access_rule:rule()).
all_rules() ->
    case ets:lookup(?ACL_RULE_TABLE, all_rules) of
        [] -> [];
        [{_, Rules}] -> Rules
    end.

%%%=============================================================================
%%% ACL callbacks 
%%%=============================================================================

%% @doc init internal ACL.
-spec init(AclOpts :: list()) -> {ok, State :: any()}.
init(AclOpts) ->
    ets:new(?ACL_RULE_TABLE, [set, public, named_table]),
    AclFile = proplists:get_value(file, AclOpts),
    Default = proplists:get_value(nomatch, AclOpts, allow),
    State = #state{acl_file = AclFile, nomatch = Default},
    load_rules(State),
    {ok, State}.

load_rules(#state{acl_file = AclFile}) ->
    {ok, Terms} = file:consult(AclFile),
    Rules = [emqttd_access_rule:compile(Term) || Term <- Terms],
    lists:foreach(fun(PubSub) ->
        ets:insert(?ACL_RULE_TABLE, {PubSub,
            lists:filter(fun(Rule) -> filter(PubSub, Rule) end, Rules)})
        end, [publish, subscribe]),
    ets:insert(?ACL_RULE_TABLE, {all_rules, Terms}).

filter(_PubSub, {allow, all}) ->
    true;
filter(_PubSub, {deny, all}) ->
    true;
filter(publish, {_AllowDeny, _Who, publish, _Topics}) ->
    true;
filter(_PubSub, {_AllowDeny, _Who, pubsub, _Topics}) ->
    true;
filter(subscribe, {_AllowDeny, _Who, subscribe, _Topics}) ->
    true;
filter(_PubSub, {_AllowDeny, _Who, _, _Topics}) ->
    false.

%% @doc Check ACL.
-spec check_acl({User, PubSub, Topic}, State) -> allow | deny | ignore when
      User   :: mqtt_user(),
      PubSub :: pubsub(),
      Topic  :: binary(),
      State  :: #state{}.
check_acl({User, PubSub, Topic}, #state{nomatch = Default}) ->
    case match(User, Topic, lookup(PubSub)) of
        {matched, allow} -> allow;
        {matched, deny}  -> deny;
        nomatch          -> Default
    end.

lookup(PubSub) ->
    case ets:lookup(?ACL_RULE_TABLE, PubSub) of
        [] -> [];
        [{PubSub, Rules}] -> Rules
    end.

match(_User, _Topic, []) ->
    nomatch;

match(User, Topic, [Rule|Rules]) ->
    case emqttd_access_rule:match(User, Topic, Rule) of
        nomatch -> match(User, Topic, Rules);
        {matched, AllowDeny} -> {matched, AllowDeny}
    end.

%% @doc Reload ACL.
-spec reload_acl(State :: #state{}) -> ok | {error, Reason :: any()}.
reload_acl(State) ->
    case catch load_rules(State) of
        {'EXIT', Error} -> {error, Error};
        _ -> ok
    end.

%% @doc ACL Description.
-spec description() -> string().
description() ->
    "Internal ACL with etc/acl.config".


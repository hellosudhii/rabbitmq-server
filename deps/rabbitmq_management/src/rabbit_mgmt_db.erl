%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Plugin.
%%
%%   The Initial Developer of the Original Code is GoPivotal, Inc.
%%   Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_mgmt_db).

-include("rabbit_mgmt.hrl").
-include("rabbit_mgmt_metrics.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_core_metrics.hrl").

-behaviour(gen_server2).

-export([start_link/0]).
-export([pget/2, id_name/1, id/2, lookup_element/2, lookup_element/3]).

-export([augment_exchanges/3, augment_queues/3,
         augment_nodes/2, augment_vhosts/2,
         get_channel/2, get_connection/2,
         get_all_channels/1, get_all_connections/1,
         get_all_consumers/0, get_all_consumers/1,
         get_overview/2, get_overview/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, handle_pre_hibernate/1,
         format_message_queue/2]).

-import(rabbit_misc, [pget/3]).

%% The management database listens to events broadcast via the
%% rabbit_event mechanism, and responds to queries from the various
%% rabbit_mgmt_wm_* modules. It handles several kinds of events, and
%% slices and dices them in various ways.
%%
%% There are three types of events coming in: created (when an object
%% is created, containing immutable facts about it), stats (emitted on
%% a timer, with mutable facts about the object), and deleted (just
%% containing the object's ID). In this context "objects" means
%% connections, channels, exchanges, queues, consumers, vhosts and
%% nodes. Note that we do not care about users, permissions, bindings,
%% parameters or policies.
%%
%% Connections and channels are identified by pids. Queues and
%% exchanges are identified by names (which are #resource{}s). VHosts
%% and nodes are identified by names which are binaries. And consumers
%% are identified by {ChPid, QName, CTag}.
%%
%% The management database records the "created" events for
%% connections, channels and consumers, and can thus be authoritative
%% about those objects. For queues, exchanges and nodes we go to
%% Mnesia to find out the immutable details of the objects.
%%
%% For everything other than consumers, the database can then augment
%% these immutable details with stats, as the object changes. (We
%% never emit anything very interesting about consumers).
%%
%% Stats on the inbound side are referred to as coarse- and
%% fine-grained. Fine grained statistics are the message rates
%% maintained by channels and associated with tuples: {publishing
%% channel, exchange}, {publishing channel, exchange, queue} and
%% {queue, consuming channel}. Coarse grained stats are everything
%% else and are associated with only one object, not a tuple.
%%
%% Within the management database though we rearrange things a bit: we
%% refer to basic stats, simple stats and detail stats.
%%
%% Basic stats are those coarse grained stats for which we do not
%% retain a history and do not perform any calculations -
%% e.g. connection.state or channel.prefetch_count.
%%
%% Simple stats are those for which we do history / calculations which
%% are associated with one object *after aggregation* - so these might
%% originate with coarse grained stats - e.g. connection.send_oct or
%% queue.messages_ready. But they might also originate from fine
%% grained stats which have been aggregated - e.g. the message rates
%% for a vhost or queue.
%%
%% Finally, detailed stats are those for which we do history /
%% calculations which are associated with two objects. These
%% have to have originated as fine grained stats, but can still have
%% been aggregated.
%%
%% Created events and basic stats are stored in ETS tables by object.
%% Simple and detailed stats (which only differ depending on how
%% they're keyed) are stored in aggregated stats tables
%% (see rabbit_mgmt_stats.erl and include/rabbit_mgmt_metrics.hrl)
%%
%% Keys from simple and detailed stats are aggregated in several
%% records, stored in different ETS tables. We store a base counter
%% for everything that happened before the samples we have kept,
%% and a series of records which add the timestamp as part of the key.
%%
%% Each ETS aggregated table has a GC process with a timer to periodically
%% aggregate old samples in the base.
%%
%% We also have old_stats to let us calculate instantaneous
%% rates, in order to apportion simple / detailed stats into time
%% slices as they come in. These instantaneous rates are not returned
%% in response to any query, the rates shown in the API are calculated
%% at query time. old_stats contains both coarse and fine
%% entries. Coarse entries are pruned when the corresponding object is
%% deleted, and fine entries are pruned when the emitting channel is
%% closed, and whenever we receive new fine stats from a channel. So
%% it's quite close to being a cache of "the previous stats we
%% received".
%%
%% Overall the object is to do all the aggregation when events come
%% in, and make queries be simple lookups as much as possible. One
%% area where this does not happen is the global overview - which is
%% aggregated from vhost stats at query time since we do not want to
%% reveal anything about other vhosts to unprivileged users.

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

start_link() ->
    gen_server2:start_link({local, ?MODULE}, ?MODULE, [], []).

%% R = Ranges, M = Mode
augment_exchanges(Xs, R, M) -> safe_call({augment_exchanges, Xs, R, M}, Xs).
augment_queues(Qs, R, M)    -> safe_call({augment_queues, Qs, R, M}, Qs).
augment_vhosts(VHosts, R)   -> safe_call({augment_vhosts, VHosts, R}, VHosts).
augment_nodes(Nodes, R)     -> safe_call({augment_nodes, Nodes, R}, Nodes).

get_channel(Name, R)        -> safe_call({get_channel, Name, R}, not_found).
get_connection(Name, R)     -> safe_call({get_connection, Name, R}, not_found).

get_all_channels(R)         -> safe_call({get_all_channels, R}).
get_all_connections(R)      -> safe_call({get_all_connections, R}).

get_all_consumers()         -> safe_call({get_all_consumers, all}).
get_all_consumers(V)        -> safe_call({get_all_consumers, V}).

get_overview(User, R)       -> safe_call({get_overview, User, R}).
get_overview(R)             -> safe_call({get_overview, all, R}).

safe_call(Term)          -> safe_call(Term, []).
safe_call(Term, Default) -> safe_call(Term, Default, 1).

%% See rabbit_mgmt_sup_sup for a discussion of the retry logic.
safe_call(Term, Default, Retries) ->
    rabbit_misc:with_exit_handler(
      fun () ->
              case Retries of
                  0 -> Default;
                  _ -> rabbit_mgmt_sup_sup:start_child(),
                       safe_call(Term, Default, Retries - 1)
              end
      end,
      fun () -> gen_server2:call(?MODULE, Term, infinity) end).

%%----------------------------------------------------------------------------
%% Internal, gen_server2 callbacks
%%----------------------------------------------------------------------------

-record(state, {interval}).

init([]) ->
    %% When Rabbit is overloaded, it's usually especially important
    %% that the management plugin work.
    process_flag(priority, high),
    {ok, Interval} = application:get_env(rabbit, collect_statistics_interval),
    rabbit_log:info("Statistics database started.~n"),
    {ok, #state{interval = Interval}, hibernate,
     {backoff, ?HIBERNATE_AFTER_MIN, ?HIBERNATE_AFTER_MIN, ?DESIRED_HIBERNATE}}.

handle_call({augment_exchanges, Xs, Ranges, basic}, _From,
            #state{interval = Interval} = State) ->
    reply(list_exchange_stats(Ranges, Xs, Interval), State);

handle_call({augment_exchanges, Xs, Ranges, full}, _From,
            #state{interval = Interval} = State) ->
    reply(detail_exchange_stats(Ranges, Xs, Interval), State);

handle_call({augment_queues, Qs, Ranges, basic}, _From,
            #state{interval = Interval} = State) ->
    reply(list_queue_stats(Ranges, Qs, Interval), State);

handle_call({augment_queues, Qs, Ranges, full}, _From,
            #state{interval = Interval} = State) ->
    reply(detail_queue_stats(Ranges, Qs, Interval), State);

handle_call({augment_vhosts, VHosts, Ranges}, _From,
            #state{interval = Interval} = State) ->
    reply(vhost_stats(Ranges, VHosts, Interval), State);

handle_call({augment_nodes, Nodes, Ranges}, _From,
            #state{interval = Interval} = State) ->
    {reply, node_stats(Ranges, Nodes, Interval), State};

handle_call({get_channel, Name, Ranges}, _From,
            #state{interval = Interval} = State) ->
    case created_stats(Name, channel_created_stats) of
        not_found -> reply(not_found, State);
        Ch        -> [Result] = detail_channel_stats(Ranges, [Ch], Interval),
                     reply(Result, State)
    end;

handle_call({get_connection, Name, Ranges}, _From,
            #state{interval = Interval} = State) ->
    case created_stats(Name, connection_created_stats) of
        not_found -> reply(not_found, State);
        Conn      -> [Result] = connection_stats(Ranges, [Conn], Interval),
                     reply(Result, State)
    end;

handle_call({get_all_channels, Ranges}, _From,
            #state{interval = Interval} = State) ->
    Chans = created_stats(channel_created_stats),
    reply(list_channel_stats(Ranges, Chans, Interval), State);

handle_call({get_all_connections, Ranges}, _From,
            #state{interval = Interval} = State) ->
    Conns = created_stats(connection_created_stats),
    reply(connection_stats(Ranges, Conns, Interval), State);

handle_call({get_all_consumers, VHost}, _From, State) ->
    {reply, [augment_msg_stats(augment_consumer(C)) ||
                C <- consumers_by_vhost(VHost)], State};

handle_call({get_overview, User, Ranges}, _From,
            #state{interval = Interval} = State) ->
    VHosts = case User of
                 all -> rabbit_vhost:list();
                 _   -> rabbit_mgmt_util:list_visible_vhosts(User)
             end,
    %% TODO: there's no reason we can't do an overview of send_oct and
    %% recv_oct now!
    MessageStats = lists:append(
		     [rabbit_mgmt_stats:format_sum(pick_range(fine_stats, Ranges),
						   Interval, vhost_stats_fine_stats, VHosts),
		      rabbit_mgmt_stats:format_sum(pick_range(queue_msg_rates, Ranges),
						   Interval, vhost_msg_rates, VHosts),
		      rabbit_mgmt_stats:format_sum(pick_range(deliver_get, Ranges),
						   Interval, vhost_stats_deliver_stats, VHosts)]),
    QueueStats = rabbit_mgmt_stats:format_sum(pick_range(queue_msg_counts, Ranges),
					      Interval, vhost_msg_stats, VHosts),
    %% Filtering out the user's consumers would be rather expensive so let's
    %% just not show it
    Consumers = case User of
                    all -> [{consumers, ets:info(consumer_stats, size)}];
                    _   -> []
                end,
    ObjectTotals = Consumers ++
        [{queues, length([Q || V <- VHosts,
			       Q <- rabbit_amqqueue:list(V)])},
         {exchanges, length([X || V <- VHosts,
				  X <- rabbit_exchange:list(V)])},
         {connections, count_created_stats(connection_created_stats, User)},
         {channels, count_created_stats(channel_created_stats, User)}],

    reply([{message_stats, MessageStats},
           {queue_totals,  QueueStats},
           {object_totals, ObjectTotals},
           {statistics_db_event_queue, event_queue()}],
          State);

handle_call(_Request, _From, State) ->
    reply(not_understood, State).

handle_cast(_Request, State) ->
    noreply(State).

handle_info(_Info, State) ->
    noreply(State).

terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

reply(Reply, NewState) -> {reply, Reply, NewState, hibernate}.
noreply(NewState) -> {noreply, NewState, hibernate}.

handle_pre_hibernate(State) ->
    %% rabbit_event can end up holding on to some memory after a busy
    %% workout, but it's not a gen_server so we can't make it
    %% hibernate. The best we can do is forcibly GC it here (if
    %% rabbit_mgmt_db is hibernating the odds are rabbit_event is
    %% quiescing in some way too).
    rpc:multicall(
      rabbit_mnesia:cluster_nodes(running), rabbit_mgmt_db_handler, gc, []),
    {hibernate, State}.

format_message_queue(Opt, MQ) -> rabbit_misc:format_message_queue(Opt, MQ).

%%----------------------------------------------------------------------------
%% Internal, utilities
%%----------------------------------------------------------------------------

pget(Key, List) -> pget(Key, List, unknown).

%% id_name() and id() are for use when handling events, id_lookup()
%% for when augmenting. The difference is that when handling events a
%% queue name will be a resource, but when augmenting we will be
%% passed a queue proplist that will already have been formatted -
%% i.e. it will have name and vhost keys.
id_name(node_stats)       -> name;
id_name(node_node_stats)  -> route;
id_name(vhost_stats)      -> name;
id_name(queue_stats)      -> name;
id_name(exchange_stats)   -> name;
id_name(channel_stats)    -> pid;
id_name(connection_stats) -> pid.

id(Type, List) -> pget(id_name(Type), List).

id_lookup(queue_stats, List) ->
    rabbit_misc:r(pget(vhost, List), queue, pget(name, List));
id_lookup(exchange_stats, List) ->
    rabbit_misc:r(pget(vhost, List), exchange, pget(name, List));
id_lookup(Type, List) ->
    id(Type, List).

lookup_element(Table, Key) -> lookup_element(Table, Key, 2).

lookup_element(Table, Key, Pos) ->
    try ets:lookup_element(Table, Key, Pos)
    catch error:badarg -> []
    end.

%%----------------------------------------------------------------------------
%% Internal, querying side
%%----------------------------------------------------------------------------
first(Id)  ->
    {Id, '_'}.

second(Id) ->
    {'_', Id}.

list_queue_stats(Ranges, Objs, Interval) ->
    adjust_hibernated_memory_use(
      [begin
	   Id = id_lookup(queue_stats, Obj),
	   Pid = pget(pid, Obj),
	   Props = lookup_element(queue_stats, Id),
	   Stats = message_stats(
		     rabbit_mgmt_stats:format(pick_range(fine_stats, Ranges),
					      queue_stats_publish,
					      Id, Interval) ++
			 rabbit_mgmt_stats:format(pick_range(deliver_get, Ranges),
						  queue_stats_deliver_stats,
						  Id, Interval)) ++
	       rabbit_mgmt_stats:format(pick_range(process_stats, Ranges),
					queue_process_stats,
					Id, Interval) ++
	       rabbit_mgmt_stats:format(pick_range(queue_msg_counts, Ranges),
					queue_msg_stats,
					Id, Interval),
	   {Pid, augment_msg_stats(combine(Props, Obj)) ++ Stats}
       end || Obj <- Objs]).

detail_queue_stats(Ranges, Objs, Interval) ->
    adjust_hibernated_memory_use(
      [begin
	   Id = id_lookup(queue_stats, Obj),
	   Pid = pget(pid, Obj),
	   Props = lookup_element(queue_stats, Id),
	   Stats = message_stats(
		     rabbit_mgmt_stats:format(pick_range(fine_stats, Ranges),
					      queue_stats_publish,
					      Id, Interval) ++
			 rabbit_mgmt_stats:format(pick_range(deliver_get, Ranges),
						  queue_stats_deliver_stats,
						  Id, Interval)) ++
	       rabbit_mgmt_stats:format(pick_range(process_stats, Ranges),
					queue_process_stats,
					Id, Interval) ++
	       rabbit_mgmt_stats:format(pick_range(queue_msg_counts, Ranges),
					queue_msg_stats,
					Id, Interval),
	   Consumers = [{consumer_details,
			 [augment_consumer(C)
			  || C <- ets:select(consumer_stats, match_queue_consumer_spec(Id))]}],
	   StatsD = [{deliveries, detail_stats(channel_queue_stats_deliver_stats,
						   deliver_get, second(Id), Ranges,
						   Interval)},
		     {incoming, detail_stats(queue_exchange_stats_publish,
						 fine_stats, first(Id), Ranges,
						 Interval)}],
	   {Pid, augment_msg_stats(combine(Props, Obj)) ++ Stats ++ StatsD ++ Consumers}
       end || Obj <- Objs]).

list_exchange_stats(Ranges, Objs, Interval) ->
    [begin
	 Id = id_lookup(exchange_stats, Obj),
	 Stats = message_stats(
		   rabbit_mgmt_stats:format(pick_range(fine_stats, Ranges),
					    exchange_stats_publish_out,
					    Id, Interval) ++
		       rabbit_mgmt_stats:format(pick_range(fine_stats, Ranges),
						exchange_stats_publish_in,
						Id, Interval)),
	 %% remove live state? not sure it has!
	 Obj ++ Stats
     end || Obj <- Objs].

detail_exchange_stats(Ranges, Objs, Interval) ->
    [begin
	 Id = id_lookup(exchange_stats, Obj),
	 Stats = message_stats(
		   rabbit_mgmt_stats:format(pick_range(fine_stats, Ranges),
					    exchange_stats_publish_out,
					    Id, Interval) ++
		       rabbit_mgmt_stats:format(pick_range(fine_stats, Ranges),
						exchange_stats_publish_in,
						Id, Interval)),
	 StatsD = [{incoming, detail_stats(channel_exchange_stats_fine_stats,
					       fine_stats, second(Id), Ranges,
					       Interval)},
		   {outgoing, detail_stats(queue_exchange_stats_publish,
					       fine_stats, second(Id), Ranges,
					       Interval)}],
	 %% remove live state? not sure it has!
	 Obj ++ StatsD ++ Stats
     end || Obj <- Objs].

connection_stats(Ranges, Objs, Interval) ->
    [begin
	 Id = id_lookup(connection_stats, Obj),
	 Props = lookup_element(connection_stats, Id), %% TODO needs formatting?
	 Stats = rabbit_mgmt_stats:format(pick_range(coarse_conn_stats, Ranges),
					  connection_stats_coarse_conn_stats,
					  Id, Interval),
	 Details = augment_details(Obj, []),
	 combine(Props, Obj) ++ Details ++ Stats
     end || Obj <- Objs].

list_channel_stats(Ranges, Objs, Interval) ->
    [begin
	 Id = id_lookup(channel_stats, Obj),
	 Props = lookup_element(channel_stats, Id),
	 %% TODO rest of stats!
	 Stats = [{message_stats,
		   rabbit_mgmt_stats:format(pick_range(fine_stats, Ranges),
					    channel_stats_fine_stats,
					    Id, Interval) ++
		       rabbit_mgmt_stats:format(pick_range(deliver_get, Ranges),
						channel_stats_deliver_stats,
						Id, Interval)} |
		  rabbit_mgmt_stats:format(pick_range(process_stats, Ranges),
					   channel_process_stats,
					   Id, Interval)],
	 augment_msg_stats(combine(Props, Obj)) ++ Stats
     end || Obj <- Objs].

detail_channel_stats(Ranges, Objs, Interval) ->
    [begin
	 Id = id_lookup(channel_stats, Obj),
	 Props = lookup_element(channel_stats, Id),
	 Stats = message_stats(
		   rabbit_mgmt_stats:format(pick_range(fine_stats, Ranges),
					     channel_stats_fine_stats,
					    Id, Interval) ++
		       rabbit_mgmt_stats:format(pick_range(deliver_get, Ranges),
						channel_stats_deliver_stats,
						Id, Interval))
	     ++ rabbit_mgmt_stats:format(pick_range(process_stats, Ranges),
					 channel_process_stats,
					 Id, Interval),
	 Consumers = [{consumer_details,
		       [augment_consumer(C)
			|| C <- ets:select(consumer_stats, match_consumer_spec(Id))]}],
	 StatsD = [{publishes, detail_stats(channel_exchange_stats_fine_stats,
						fine_stats, first(Id), Ranges,
						Interval)},
		   {deliveries, detail_stats(channel_queue_stats_deliver_stats,
						 fine_stats, first(Id), Ranges,
						 Interval)}],
	 augment_msg_stats(combine(Props, Obj)) ++ Consumers ++ Stats ++ StatsD
     end || Obj <- Objs].

augment_consumer({{Q, Ch, CTag}, Props}) ->
    [{queue, rabbit_mgmt_format:resource(Q)},
     {channel_details, augment_channel_pid(Ch)},
     {consumer_tag, CTag} | Props].

detail_stats(Table, Type, Id, Ranges, Interval) ->
    [begin
	 S = rabbit_mgmt_stats:format(pick_range(Type, Ranges), Table, Key, Interval),
	 [{stats, S} | format_detail_id(revert(Id, Key))]
     end || Key <- rabbit_mgmt_stats:get_keys(Table, Id)].

vhost_stats(Ranges, Objs, Interval) ->
    [begin
	 Id = id_lookup(vhost_stats, Obj),
	 Stats = rabbit_mgmt_stats:format(pick_range(coarse_conn_stats, Ranges),
					  vhost_stats_coarse_conn_stats,
					  Id, Interval)
	     ++ rabbit_mgmt_stats:format(pick_range(queue_msg_rates, Ranges),
					 vhost_msg_stats, Id, Interval),
	 StatsD = message_stats(rabbit_mgmt_stats:format(pick_range(fine_stats, Ranges),
							 vhost_stats_fine_stats,
							 Id, Interval)
				++ rabbit_mgmt_stats:format(pick_range(deliver_get, Ranges),
							    vhost_stats_deliver_stats,
							    Id, Interval)),
	 Details = augment_details(Obj, []),
	 Obj ++ Details ++ Stats ++ StatsD
     end || Obj <- Objs].

node_stats(Ranges, Objs, Interval) ->
    [begin
	 Id = id_lookup(node_stats, Obj),
	 Props = lookup_element(node_stats, Id),
	 Stats = rabbit_mgmt_stats:format(pick_range(coarse_node_stats, Ranges),
					  node_coarse_stats,
					  Id, Interval)
	     ++ rabbit_mgmt_stats:format(pick_range(coarse_node_stats, Ranges),
					 node_persister_stats,
					 Id, Interval),
	 StatsD = [{cluster_links, detail_stats(node_node_coarse_stats,
						    coarse_node_node_stats, first(Id), Ranges,
						    Interval)}],
	 Details = augment_details(Obj, []),
	 combine(Props, Obj) ++ Details ++ Stats ++ StatsD
     end || Obj <- Objs].

combine(New, Old) ->
    case pget(state, Old) of
        unknown -> New ++ Old;
        live    -> New ++ lists:keydelete(state, 1, Old);
        _       -> lists:keydelete(state, 1, New) ++ Old
    end.

revert({'_', _}, {Id, _}) ->
    Id;
revert({_, '_'}, {_, Id}) ->
    Id.

format_detail_id(ChPid) when is_pid(ChPid) ->
    augment_msg_stats([{channel, ChPid}]);
format_detail_id(#resource{name = Name, virtual_host = Vhost, kind = Kind}) ->
    [{Kind, [{name, Name}, {vhost, Vhost}]}];
format_detail_id(Node) when is_atom(Node) ->
    [{name, Node}].

pick_range(queue_msg_counts, {RangeL, _RangeM, _RangeD, _RangeN}) ->
    RangeL;
pick_range(K, {_RangeL, RangeM, _RangeD, _RangeN}) when K == fine_stats;
                                                        K == deliver_get;
                                                        K == queue_msg_rates ->
    RangeM;
pick_range(K, {_RangeL, _RangeM, RangeD, _RangeN}) when K == coarse_conn_stats;
                                                        K == process_stats ->
    RangeD;
pick_range(K, {_RangeL, _RangeM, _RangeD, RangeN})
  when K == coarse_node_stats;
       K == coarse_node_node_stats ->
    RangeN.

%% We do this when retrieving the queue record rather than when
%% storing it since the memory use will drop *after* we find out about
%% hibernation, so to do it when we receive a queue stats event would
%% be fiddly and racy. This should be quite cheap though.
adjust_hibernated_memory_use(Qs) ->
    Pids = [Pid || {Pid, Q} <- Qs, pget(idle_since, Q, not_idle) =/= not_idle],
    %% We use delegate here not for ordering reasons but because we
    %% want to get the right amount of parallelism and minimise
    %% cross-cluster communication.
    {Mem, _BadNodes} = delegate:invoke(Pids, {erlang, process_info, [memory]}),
    MemDict = dict:from_list([{P, M} || {P, M = {memory, _}} <- Mem]),
    [case dict:find(Pid, MemDict) of
         error        -> Q;
         {ok, Memory} -> [Memory|proplists:delete(memory, Q)]
     end || {Pid, Q} <- Qs].


created_stats(Name, Type) ->
    case ets:select(Type, [{{'_', '$2', '$3'}, [{'==', Name, '$2'}], ['$3']}]) of
        [] -> not_found;
        [Elem] -> Elem
    end.

created_stats(Type) ->
    %% TODO better tab2list?
    ets:select(Type, [{{'_', '_', '$3'}, [], ['$3']}]).

count_created_stats(Type, all) ->
    ets:info(Type, size);
count_created_stats(Type, User) ->
    length(rabbit_mgmt_util:filter_user(created_stats(Type), User)).

consumers_by_vhost(VHost) ->
    ets:select(consumer_stats,
               [{{{#resource{virtual_host = '$1', _ = '_'}, '_', '_'}, '_'},
                 [{'orelse', {'==', 'all', VHost}, {'==', VHost, '$1'}}],
                 ['$_']}]).

%%----------------------------------------------------------------------------
%% Internal, query-time augmentation
%%----------------------------------------------------------------------------

augment_msg_stats(Props) ->
    rabbit_mgmt_format:strip_pids(
      (augment_msg_stats_fun())(Props) ++ Props).

augment_msg_stats_fun() ->
    fun(Props) ->
            augment_details(Props, [])
    end.

augment_details([{_, none} | T], Acc) ->
    augment_details(T, Acc);
augment_details([{_, unknown} | T], Acc) ->
    augment_details(T, Acc);
augment_details([{connection, Value} | T], Acc) ->
    augment_details(T, [{connection_details, augment_connection_pid(Value)} | Acc]);
augment_details([{channel, Value} | T], Acc) ->
    augment_details(T, [{channel_details, augment_channel_pid(Value)} | Acc]);
augment_details([{owner_pid, Value} | T], Acc) ->
    augment_details(T, [{owner_pid_details, augment_connection_pid(Value)} | Acc]);
augment_details([_ | T], Acc) ->
    augment_details(T, Acc);
augment_details([], Acc) ->
    Acc.

augment_channel_pid(Pid) ->
    Ch = lookup_element(channel_created_stats, Pid, 3),
    Conn = lookup_element(connection_created_stats, pget(connection, Ch), 3),
    case Conn of
	[] -> %% If the connection has just been opened, we might not yet have the data
	    [];
	_ ->
	    [{name,            pget(name,   Ch)},
	     {number,          pget(number, Ch)},
	     {user,            pget(user,   Ch)},
	     {connection_name, pget(name,         Conn)},
	     {peer_port,       pget(peer_port,    Conn)},
	     {peer_host,       pget(peer_host,    Conn)}]
    end.

augment_connection_pid(Pid) ->
    Conn = lookup_element(connection_created_stats, Pid, 3),
    case Conn of
	[] -> %% If the connection has just been opened, we might not yet have the data
	    [];
	_ ->
	    [{name,         pget(name,         Conn)},
	     {peer_port,    pget(peer_port,    Conn)},
	     {peer_host,    pget(peer_host,    Conn)}]
    end.

event_queue() ->
    lists:foldl(fun (T, Sum) ->
                    case whereis(rabbit_mgmt_metrics_collector:name(T)) of
                        P when is_pid(P) ->
                            {message_queue_len, Len} =
                                erlang:process_info(P, message_queue_len),
                                Sum + Len;
                        _ -> Sum
                    end
                end, 0, ?CORE_TABLES).

match_consumer_spec(Id) ->
    [{{{'_', '$1', '_'}, '_'}, [{'==', Id, '$1'}], ['$_']}].

match_queue_consumer_spec(Id) ->
    [{{{'$1', '_', '_'}, '_'}, [{'==', {Id}, '$1'}], ['$_']}].

message_stats([]) ->
    [];
message_stats(Stats) ->
    [{message_stats, Stats}].

## The contents of this file are subject to the Mozilla Public License
## Version 1.1 (the "License"); you may not use this file except in
## compliance with the License. You may obtain a copy of the License
## at http://www.mozilla.org/MPL/
##
## Software distributed under the License is distributed on an "AS IS"
## basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
## the License for the specific language governing rights and
## limitations under the License.
##
## The Original Code is RabbitMQ.
##
## The Initial Developer of the Original Code is Pivotal Software, Inc.
## Copyright (c) 2016 Pivotal Software, Inc.  All rights reserved.


defmodule RenameClusterNodeCommandTest do
  use ExUnit.Case, async: false
  import TestHelper

  @command RabbitMQ.CLI.Ctl.Commands.RenameClusterNodeCommand

  setup_all do
    RabbitMQ.CLI.Distribution.start()
    node = get_rabbit_hostname
    :net_kernel.connect_node(node)

    start_rabbitmq_app

    {:ok, rabbitmq_home} = :rabbit_misc.rpc_call(node, :file, :get_cwd, [])
    mnesia_dir = :rabbit_misc.rpc_call(node, :rabbit_mnesia, :dir, [])

    on_exit([], fn ->
      start_rabbitmq_app
      :erlang.disconnect_node(node)

    end)

    {:ok, opts: %{rabbitmq_home: rabbitmq_home, mnesia_dir: mnesia_dir}}
  end

  setup context do
    {:ok, opts: Map.merge(context[:opts],
                          %{node: :not_running@localhost})
    }
  end

  test "validate: specifying an uneven number of arguments fails validation", context do
    assert match?(
      {:validation_failure, {:bad_argument, _}},
      @command.validate(["a", "b", "c"], context[:opts]))
  end

  test "validate: specifying no nodes fails validation", context do
    assert @command.validate([], context[:opts]) ==
      {:validation_failure, :not_enough_args}
  end

  test "validate: specifying one node only fails validation", context do
    assert @command.validate(["a"], context[:opts]) ==
      {:validation_failure, :not_enough_args}
  end

  test "validate: request to a running node fails", _context do
    node = get_rabbit_hostname
    assert match?({:validation_failure, :node_running},
      @command.validate([to_string(node), "other_node@localhost"], %{node: node}))
  end

  test "validate: not providing node mnesia dir fails validation", context do
    opts_without_mnesia = Map.delete(context[:opts], :mnesia_dir)
    assert match?({:validation_failure, :mnesia_dir_not_found},
      @command.validate(["some_node@localhost", "other_node@localhost"], opts_without_mnesia))
    Application.put_env(:mnesia, :dir, "/tmp")
    on_exit(fn -> Application.delete_env(:mnesia, :dir) end)
    assert :ok == @command.validate(["some_node@localhost", "other_node@localhost"], opts_without_mnesia)
    Application.delete_env(:mnesia, :dir)
    System.put_env("RABBITMQ_MNESIA_DIR", "/tmp")
    on_exit(fn -> System.delete_env("RABBITMQ_MNESIA_DIR") end)
    assert :ok == @command.validate(["some_node@localhost", "other_node@localhost"], opts_without_mnesia)
    System.delete_env("RABBITMQ_MNESIA_DIR")
    assert :ok == @command.validate(["some_node@localhost", "other_node@localhost"], context[:opts])
  end

  test "banner", context do
    assert @command.banner(["a", "b"], context[:opts]) =~
      ~r/Renaming cluster nodes: \n a -> b/
  end
end

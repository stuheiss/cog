defmodule Cog.Support.TestCommands.RequiredOptTestCommand do
  use Cog.Command.GenCommand.Base, bundle: Cog.embedded_bundle, enforcing: false, name: "req-opt"

  option "req", type: "string", required: true

  def handle_message(req, state) do
    {:reply, req.reply_to, "req-opt response", state}
  end
end

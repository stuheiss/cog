defmodule Cog.Chat.Adapter do

  require Logger

  use GenServer

  alias Carrier.Messaging.{Connection, ConnectionSup}
  alias Cog.Chat.Room
  alias Cog.Chat.Message
  alias Cog.Chat.User
  alias Cog.Messages.ProviderRequest
  alias Cog.Pipeline.Initializer
  alias Cog.Util.CacheSup
  alias Cog.Util.Cache

  @incoming_message_topic "bot/chat/adapter/incoming/message"
  @incoming_event_topic "bot/chat/adapter/incoming/event"
  @cache_name :cog_chat_adapter_cache

  defstruct [:conn, :providers, :cache]

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def mention_name(provider, handle) when is_binary(handle) do
    GenServer.call(__MODULE__, {:mention_name, provider, handle}, :infinity)
  end

  def display_name(provider) do
    GenServer.call(__MODULE__, {:display_name, provider}, :infinity)
  end

  def lookup_user(provider, handle) when is_binary(handle) do
    cache = get_cache
    case cache[{provider, :user, handle}] do
      nil ->
        case GenServer.call(__MODULE__, {:lookup_user, provider, handle}, :infinity) do
          {:ok, user} ->
            User.from_map(user)
          {:error, _}=error ->
            error
        end
      {:ok, value} ->
        User.from_map(value)
    end
  end

  # Declaring like this so we fail quickly if lookup_room
  # is called with something other than a keyword list.
  def lookup_room(provider, name: name),
    do: do_lookup_room(provider, name: name)
  def lookup_room(provider, id: id),
    do: do_lookup_room(provider, id: id)

  # room_identifier should come in as a keyword list with
  # either [id: id] or [name: name]
  defp do_lookup_room(provider, room_identifier) do
    args = Enum.into(room_identifier, %{provider: provider})
    cache = get_cache
    case cache[{provider, :room, room_identifier}] do
      nil ->
        case GenServer.call(__MODULE__ , {:lookup_room, args}, :infinity) do
          {:ok, room} ->
            Room.from_map(room)
          {:error, _}=error ->
            error
        end
      {:ok, value} ->
        Room.from_map(value)
    end
  end

  def list_joined_rooms(provider) do
    case GenServer.call(__MODULE__, {:list_joined_rooms, provider}, :infinity) do
      nil ->
        nil
      {:ok, rooms} ->
        {:ok, Enum.map(rooms, &Room.from_map!/1)}
    end
  end

  def join(provider, room) when is_binary(room) do
    GenServer.call(__MODULE__, {:join, provider, room}, :infinity)
  end

  def leave(provider, room) when is_binary(room) do
    GenServer.call(__MODULE__, {:leave, provider, room}, :infinity)
  end

  def list_providers() do
    GenServer.call(__MODULE__, :list_providers, :infinity)
  end

  def is_chat_provider?(name) do
    {:ok, result} = GenServer.call(__MODULE__, {:is_chat_provider, name}, :infinity)
    result
  end

  def send(provider, target, message) do
    case prepare_target(target) do
      {:ok, target} ->
        GenServer.cast(__MODULE__, {:send, provider, target, message})
      error ->
        Logger.error("#{inspect error}")
        error
    end
  end

  ##########
  # Internals start here
  ##########

  def init(_) do
    case ConnectionSup.connect() do
      {:ok, conn} ->
        Logger.info("Starting")
        case Application.fetch_env(:cog, __MODULE__) do
          :error ->
            {:stop, :missing_chat_adapter_config}
          {:ok, config} ->
          case Keyword.get(config, :providers) do
            nil ->
              Logger.error("Chat provider not specified. You must specify one of 'COG_SLACK_ENABLED' or 'COG_HIPCHAT_ENABLED' env variables")
              {:stop, :missing_chat_providers}
            providers ->
              # TODO: validate that these providers actually implement
              # the proper behavior
              finish_initialization(conn, providers)
          end
        end
      error ->
        {:stop, error}
    end
  end

  # RPC calls

  def handle_call({:lookup_room, %{provider: provider, id: id}}, _from, state) do
    {:reply, maybe_cache(with_provider(provider, state, :lookup_room, [id: id]), {provider, :room, id}, state), state}
  end
  def handle_call({:lookup_room, %{provider: provider, name: name}}, _from, state) do
    {:reply, maybe_cache(with_provider(provider, state, :lookup_room, [name: name]), {provider, :room, name}, state), state}
  end
  def handle_call({:lookup_user, provider, handle}, _from, state) do
    {:reply, maybe_cache(with_provider(provider, state, :lookup_user, [handle]), {provider, :user, handle}, state), state}
  end
  def handle_call({:list_joined_rooms, provider}, _from, state) do
    {:reply, with_provider(provider, state, :list_joined_rooms, []), state}
  end
  def handle_call({:join, provider, room}, _from, state) do
    {:reply, with_provider(provider, state, :join, [room]), state}
  end
  def handle_call({:leave, provider, room}, _from, state) do
    {:reply, with_provider(provider, state, :leave, [room]), state}
  end
  def handle_call(:list_providers, _from, state) do
    {:reply, {:ok, %{providers: Enum.filter(Map.keys(state.providers), &(is_binary(&1)))}}, state}
  end
  def handle_call({:is_chat_provider, name}, _from, state) do
    {:reply, {:ok, name != "http"}, state}
  end
  def handle_call({:mention_name, provider, handle}, _from, state) do
    {:reply, with_provider(provider, state, :mention_name, [handle]), state}
  end
  def handle_call({:display_name, provider}, _from, state) do
    {:reply, with_provider(provider, state, :display_name, []), state}
  end


  # Non-blocking "cast" messages
  def handle_cast({:send, provider, target, message}, state) do
    case with_provider(provider, state, :send_message, [target, message]) do
      :ok ->
        :ok
      {:error, :not_implemented} ->
        Logger.error("send_message function not implemented for provider '#{provider}'! No message sent")
      {:error, reason} ->
        Logger.error("Failed to send message to provider #{provider}: #{inspect reason, pretty: true}")
    end
    {:noreply, state}
  end

  def handle_info({:publish, @incoming_event_topic, event}, state) do
    Logger.debug("Received chat event: #{inspect Poison.decode!(event, [keys: :string])}")
    {:noreply, state}
  end
  def handle_info({:publish, @incoming_message_topic, message}, state) do
    state = case Message.decode(message) do
              {:ok, message} ->
                case is_pipeline?(message) do
                  {true, text} ->
                    # if message.edited == true do
                    #   mention_name = with_provider(message.provider, state, :mention_name, [message.user.handle])
                    #   send(conn, message.provider, message.room, "#{mention_name} Executing edited command '#{text}'")
                    # end
                    request = %ProviderRequest{text: text, sender: message.user, room: message.room, reply: "", id: message.id,
                                               provider: message.provider, initial_context: message.initial_context || %{}}
                    Initializer.start_pipeline(request)
                    state
                  false ->
                    state
                end
              error ->
                Logger.error("Error decoding chat message: #{inspect error}   #{inspect message, pretty: true}")
                state
            end
    {:noreply, state}
  end

  defp finish_initialization(conn, providers) do
    Connection.subscribe(conn, @incoming_message_topic)
    Connection.subscribe(conn, @incoming_event_topic)
    case start_providers(providers, %{}) do
      {:ok, providers} ->
        {:ok, %__MODULE__{conn: conn, providers: providers, cache: get_cache()}}
      error ->
        error
    end
  end

  defp start_providers([], accum), do: {:ok, accum}
  defp start_providers([{name, provider}|t], accum) do
    case Application.fetch_env(:cog, provider) do
      :error ->
        {:error, {:missing_provider_config, provider}}
      {:ok, config} ->
        config = [{:incoming_message_topic, @incoming_message_topic},
                  {:incoming_event_topic, @incoming_event_topic}|config]
        case provider.start_link(config) do
          {:ok, _} ->
            Logger.info("Chat provider '#{name}' (#{provider}) initialized.")
            accum = accum |> Map.put(name, provider) |> Map.put(Atom.to_string(name), provider)
            start_providers(t, accum)
          error ->
            Logger.error("Chat provider '#{name}' (#{provider}) failed to initialize: #{inspect error}")
            error
        end
    end
  end

  defp with_provider(provider, state, fun, args) when is_atom(fun) and is_list(args) do
    case Map.get(state.providers, provider) do
      nil ->
        {:error, :unknown_provider}
      provider ->
        apply(provider, fun, args)
    end
  end

  defp is_pipeline?(message) do
    # The notion of "bot name" only really makes sense in the context
    # of chat providers, where we can use that to determine whether or
    # not a message is being addressed to the bot. For other providers
    # (lookin' at you, Http.Provider), this makes no sense, because all
    # messages are directed to the bot, by definition.
    if message.room.is_dm == true do
      {true, message.text}
    else
      case parse_spoken_command(message.text) do
        nil ->
          case parse_mention(message.text, message.bot_name) do
            nil ->
              false
            updated ->
              {true, updated}
          end
        updated ->
          {true, updated}
      end
    end
  end

  defp parse_spoken_command(text) do
    case Application.get_env(:cog, :enable_spoken_commands, true) do
      false ->
        nil
      true ->
        command_prefix = Application.get_env(:cog, :command_prefix, "!")
        updated = Regex.replace(~r/^#{Regex.escape(command_prefix)}/, text, "")

        case updated do
          ^text ->
            nil
          "" ->
            nil
          updated ->
            updated
        end
    end
  end

 defp parse_mention(_text, nil), do: nil
 defp parse_mention(text, bot_name) do
   updated = Regex.replace(~r/^#{Regex.escape(bot_name)}/i, text, "")
   if updated != text do
      Regex.replace(~r/^:/, updated, "")
      |> String.trim
   else
     nil
   end
 end

 defp prepare_target(target) do
   case Cog.Chat.Room.from_map(target) do
     {:ok, room} ->
       {:ok, room.id}
     error ->
       error
   end
 end

 defp fetch_cache_ttl do
   config = Application.get_env(:cog, __MODULE__)
   Keyword.get(config, :cache_ttl, {10, :sec})
 end

 defp get_cache do
   ttl = fetch_cache_ttl
   {:ok, cache} = CacheSup.get_or_create_cache(@cache_name, ttl)
   cache
 end

 defp maybe_cache({:ok, _}=value, key, state) do
   Cache.put(state.cache, key, value)
   value
 end
 defp maybe_cache(value, _key, _state), do: value

end

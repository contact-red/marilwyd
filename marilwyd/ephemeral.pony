use "collections"
use "json"

primitive MaxTypists
  """
  How many people a room reports as typing.

  A bound because the list is rendered into every member's sync and a
  bridged channel's membership is driven from outside. Nobody reads a
  notice naming twenty people, so the cap is well below anything a room
  would want to show.
  """
  fun apply(): USize => 20

class val Ephemeral
  """
  What a room knows that is not part of its history: who has read how far,
  and who is typing.

  Ephemeral in the specification's sense and in marilwyd's: it is never an
  event in a timeline, nothing is kept when the process ends, and a client
  that misses one has missed nothing it cannot infer from the next.

  One value rather than two, because both are read at the same moment — a
  sync renders them into one block — and a room that has neither renders
  nothing at all.
  """
  let receipts: Array[Receipt] val
  let typing: Array[String] val

  new val create(
    receipts': Array[Receipt] val,
    typing': Array[String] val)
  =>
    receipts = receipts'
    typing = typing'

  fun val size(): USize =>
    receipts.size() + typing.size()

class val Receipt
  """
  One person's read position in one room.

  The timestamp is the server's, taken when the receipt arrives. A client
  sends none, and the one it would show is when the reading happened rather
  than when it was reported — which nobody can know.
  """
  let user_id: String
  let event_id: String
  let at: I64

  new val create(user_id': String, event_id': String, at': I64) =>
    user_id = user_id'
    event_id = event_id'
    at = at'

primitive EphemeralEvents
  """
  Render a room's ephemeral block.

  Receipts are grouped by the event they name, because that is the shape a
  client reads: one `m.receipt` event whose content maps an event id to the
  people who have read that far. A separate event per person would be a
  document a client has to merge itself, and the specification does not
  describe one.
  """
  fun apply(ephemeral: Ephemeral): String =>
    recover val
      let out = String(256)
      out.append("[")
      var first = true

      if ephemeral.receipts.size() > 0 then
        let by_event = Map[String, Array[Receipt]]
        for receipt in ephemeral.receipts.values() do
          try
            by_event(receipt.event_id)?.push(receipt)
          else
            let fresh = Array[Receipt]
            fresh.push(receipt)
            by_event(receipt.event_id) = fresh
          end
        end

        first = false
        out.append("{\"type\":\"m.receipt\",\"content\":{")
        var event_first = true
        for (event_id, receipts) in by_event.pairs() do
          if not event_first then
            out.append(",")
          end
          event_first = false
          out.append(JsonPrinter.print(event_id))
          out.append(":{\"m.read\":{")
          var who_first = true
          for receipt in receipts.values() do
            if not who_first then
              out.append(",")
            end
            who_first = false
            out.append(JsonPrinter.print(receipt.user_id))
            out.append(":{\"ts\":")
            out.append(receipt.at.string())
            out.append("}")
          end
          out.append("}}")
        end
        out.append("}}")
      end

      // Emitted only when somebody is typing. An empty list is how a
      // client is told that nobody is any more, so it has to be sent when
      // the last person stops — which is a change, and reaches a client as
      // one. Sending it on every sync regardless would be a room saying
      // "nobody is typing" forever.
      if ephemeral.typing.size() > 0 then
        if not first then
          out.append(",")
        end
        out.append("{\"type\":\"m.typing\",\"content\":{\"user_ids\":[")
        var who_first = true
        for who in ephemeral.typing.values() do
          if not who_first then
            out.append(",")
          end
          who_first = false
          out.append(JsonPrinter.print(who))
        end
        out.append("]}}")
      end

      out.append("]")
      out
    end

primitive MaxRoomMembers
  """
  How many people one room will hold.

  A bridged room's membership comes from the network on the other side,
  which marilwyd does not control: a channel's name list is whatever that
  server says it is, and a server that is hostile or merely broken can say
  anything. Every member costs a permanent state slot and a delivery on
  every event, so an unbounded list is an unbounded room.

  Large enough that no real channel meets it — the biggest on a public
  network run to a few thousand — so the bound is only ever felt by
  something that is not a real channel.
  """
  fun apply(): USize => 10_000

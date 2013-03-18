require 'socket'

require 'log'
require 'packet'
require 'session'

# This class should be totally stateless, and rely on the Session class
# for any long-term session storage
class Dnscat2
  def Dnscat2.handle_syn(pipe, packet, session)
    # Ignore errant SYNs - they are, at worst, retransmissions that we don't care about
    if(!session.syn_valid?())
      Log.log(session.id, "SYN invalid in this state (ignored)")
      return nil
    end

    Log.log(session.id, "Received SYN; responding with SYN")

    session.set_their_seq(packet.seq)
    session.set_established()

    return Packet.create_syn(session.id, session.my_seq, nil)
  end

  def Dnscat2.handle_msg(pipe, packet, session)
    if(!session.msg_valid?())
      Log.log(session.id, "MSG invalid in this state (responding with an error)")
      return Packet.create_fin(session.id)
    end

    # Validate the sequence number
    if(session.their_seq != packet.seq)
      Log.log(session.id, "Bad sequence number; expected 0x%04x, got 0x%04x [re-sending]" % [session.their_seq, packet.seq])

      # Re-send the last packet
      old_data = session.read_outgoing(pipe.max_packet_size - Packet.msg_header_size)
      return Packet.create_msg(session.id, session.my_seq, session.their_seq, old_data)
    end

    if(!session.valid_ack?(packet.ack))
      Log.log(session.id, "Impossible ACK received: 0x%04x, current SEQ is 0x%04x [re-sending]" % [packet.ack, session.my_seq])

      # Re-send the last packet
      old_data = session.read_outgoing(pipe.max_packet_size - Packet.msg_header_size)
      return Packet.create_msg(session.id, session.my_seq, session.their_seq, old_data)
    end

    # Acknowledge the data that has been received so far
    session.ack_outgoing(packet.ack)

    # Write the incoming data to the session
    session.queue_incoming(packet.data)

    # Increment the expected sequence number
    session.increment_their_seq(packet.data.length)

    new_data = session.read_outgoing(pipe.max_packet_size - Packet.msg_header_size)
    Log.log(session.id, "Received MSG with #{packet.data.length} bytes; responding with our own message (#{new_data.length} bytes)")
    Log.log(session.id, ">> \"#{packet.data}\"")
    Log.log(session.id, "<< \"#{new_data}\"")

    # Build the new packet
    return Packet.create_msg(session.id, session.my_seq, session.their_seq, new_data)
  end

  def Dnscat2.handle_fin(pipe, packet, session)
    if(!session.fin_valid?())
      Log.log(session.id, "FIN invalid in this state")
      return Packet.create_fin(session.id)
    end

    session.destroy()
    return Packet.create_fin(session.id)
  end

  def Dnscat2.go(pipe)
    if(pipe.max_packet_size < 16)
      raise(Exception, "max_packet_size is too small")
    end

    session_id = nil
    begin
      loop do
        packet = Packet.parse(pipe.recv())
        session = Session.find(packet.session_id)

        response = nil
        if(packet.type == Packet::MESSAGE_TYPE_SYN)
          response = handle_syn(pipe, packet, session)
        elsif(packet.type == Packet::MESSAGE_TYPE_MSG)
          response = handle_msg(pipe, packet, session)
        elsif(packet.type == Packet::MESSAGE_TYPE_FIN)
          response = handle_fin(pipe, packet, session)
        else
          raise(IOError, "Unknown packet type: #{packet.type}")
        end

        if(response)
          if(response.length > pipe.max_packet_size)
            raise(IOError, "Tried to send packet longer than max_packet_length")
          end
          pipe.send(response)
        end
      end
    rescue IOError => e
      if(!session_id.nil?)
        Session.destroy(session_id)
      end

      puts(e.inspect)
      puts(e.backtrace)
    end

    pipe.close()
  end
end
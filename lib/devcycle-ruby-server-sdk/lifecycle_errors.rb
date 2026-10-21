module DevCycle
  # Raised when a client's local bucketing engine is used after it was closed.
  class ClientClosedError < StandardError
  end

  # Raised when a local bucketing client is used in a process forked from the
  # one that created it. Background threads do not survive a fork, so the
  # inherited client would no longer receive config updates or send events.
  # Create a new client in the forked process instead.
  class ForkedClientError < StandardError
  end
end

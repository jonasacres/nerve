module Nerve
  class PollMonitor
    include Nerve

    def self.shared
      @shared ||= self.new
    end

    def initialize
      @deadlines = {}
      start!
    end

    def stop!
      @stopped = true
    end

    def stopped?
      @done_stopping
    end

    def start!
      @stopped = @done_stopping = false
      Thread.new do
        while !@stopped do
          begin
            check_endpoints
          rescue Exception => exc
            log_error "Poll monitor thread encountered exception", exc
          end

          delay = [0, next_poll_time - Time.now].max
          sleep delay
        end

        @done_stopping = true
      end
    end

    def next_poll_time
      times = checkable_endpoints.map do |ep|
        return Time.now if ep.last_update.nil?
        ep.last_update + 0.001*ep.poll_interval_ms
      end

      times.min
    end

    def checkable_endpoints
      Endpoint
        .all
        .select { |ep| ep.poll_interval_ms && ep.poll_interval_ms > 0}
    end

    def check_endpoints
      stale = checkable_endpoints.select do |ep|
        elapsed = ep.last_update \
          ? Time.now - ep.last_update
          : ep.poll_interval_ms
         elapsed >= 0.001*ep.poll_interval_ms
      end

      log "Checking endpoints; total=#{Endpoint.all.count}, pollable=#{checkable_endpoints.count}, stale=#{stale.count}"

      stale
        .each do |ep|
          log "Autopolling endpoint: #{ep.path}"
          ep.value
        end
    end
  end
end

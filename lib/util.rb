module Nerve
  class ShellCommandFailedException < StandardError
    attr_reader :cmd, :status, :stdin, :stdout, :stderr
    def initialize(cmd, status, stdin, stdout, stderr)
      @cmd = cmd
      @status = status
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
    end

    def to_s
      sprintf("Shell command failed.\n%s@%s %s}$ %s\n%s:\n%s\n\n%s:\n%s\n\n%s:\n%s\n\n",
        `whoami`.strip,
        `hostname`.strip,
        `pwd`.strip,
        cmd.bold.green,
        "STDIN".bold,
        stdin ? stdin : "  (none)".light_black,
        "STDOUT".bold,
        stdout,
        "STDERR".bold,
        stderr
        )
    end
  end

  def web(method, url, data=nil, params={})
    args = { max_attempts:3, retry_delay:0.1, log_error:true }.merge(params)
    attempts = 0

    begin
      attempts += 1
      case method
      when :get, :delete, :head
        RestClient.send(method, url).body
      else
        RestClient.send(method, url, data, content_type:"text/plain").body
      end
    rescue Exception => exc
      return exc if args[:tolerate_error]
      if args[:log_error] then
        log "Request for #{method.to_s.upcase} #{url} failed; attempt #{attempts} of #{args[:max_attempts]}", exc
      end

      raise exc if attempts >= args[:max_attempts]
      sleep args[:retry_delay]
      retry
    end
  end

  def command(cmd, params={})
    # puts cmd.light_black
    Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
      stdin.write(params[:stdin]) if params[:stdin]
      stdin.close

      out = stdout.read
      err = stderr.read

      if wait_thr.value != 0 && !params[:tolerate_error]
        # puts "\t#{out.length.to_s.red} bytes, exit code #{wait_thr.value.to_i}"
        raise ShellCommandFailedException.new(cmd,
          wait_thr.value,
          params[:stdin],
          out,
          err)
      end

      # puts "\t#{out.length.to_s.green} bytes"
      return out
    end
  end

  def build_log(msg, exc=nil)
    out = "#{Time.now.strftime("%Y-%m-%d %H:%M:%S.%L ").bold} "
    msg = msg.split("\n") if msg.respond_to?(:split) && msg.include?("\n")
    if msg.is_a?(Array) then
      out += "\n"
      msg.each do |line|
        out += "  "
        out += line + "\n"
      end
    else
      out += msg
    end

    if exc then
      out += "\nException: #{exc.class.to_s.red} #{exc.to_s}\n"
      out += exc.backtrace.map { |line| "  " + line }.join("\n")
      out += "\n"
    end

    out += "\n"
    out
  end

  def log(msg, exc=nil)
    print build_log(msg, exc)
  end

  def log_error(msg, exc=nil)
    STDERR.print build_log(msg, exc)
  end
end

module Nerve
  require 'sinatra/base'

  class WebApp < Sinatra::Base

    set :show_exceptions, true
    set :raise_errors, true 

    helpers do
      include Nerve

      def make_default(path)
        Endpoint.add(
          path:path,
          logged:false,
          max_log_age_ms:nil,
          max_log_count:nil,
          min_log_spacing_s:nil,
          poll_interval_ms:nil,
          datatype: "text",
          source: "keystore")
      end
    end

    get '/endpoints' do
      Endpoint
        .all
        .map { |ep| ep.to_h }
        .to_json
    end

    delete '/callbacks/:id' do
      Callback.delete(params[:id].to_i)
      nil
    end

    post '/callbacks' do
      info = JSON.parse(request.body.read, symbolize_names:true)
      ep = Endpoint.named(info[:path]) || make_default(info[:path])
      Callback.add(ep,
        info[:method] || :post,
        info[:url],
        info[:type] || "update")
      nil
    end

    put '*' do |path|
      Endpoint.named(path) and halt 409
      log "Creating endpoint: #{path}"
      params = JSON.parse(request.body.read, symbolize_names:true)
      params[:path] = path
      ep = Endpoint.add(params)
      ep.datalog.scrub!

      nil
    end

    get '*' do |path|
      ep = Endpoint.named(path) or halt 404
      ep.value
    end

    post '*' do |path|
      ep = Endpoint.named(path) || make_default(path)
      ep.source == "keystore" or halt 400
      ep.value = request.body.read
      nil
    end

    delete '*' do |path|
      Endpoint.delete(path)
      nil
    end
  end
end

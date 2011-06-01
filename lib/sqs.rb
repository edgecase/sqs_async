require 'uri'
require 'cgi'
require 'hmac'
require 'hmac-sha2'
require 'base64'
require 'net/http'
require 'time'
require 'nokogiri'
require 'json'
require 'eventmachine'
require 'em-http-request'
require 'sqs_message'
require 'sqs_queue'
require 'sqs_attributes'
require 'sqs_utilities'
require 'core_ext/hash'
require 'logger'

module SQS
  include SQS::Utilities

  attr_accessor :aws_key, :aws_secret, :regions, :default_parameters, :post_options

  def change_message_visibility
    raise "Not Implemented Yet."
  end

  def set_queue_attributes
    raise "Not Implemented Yet."
  end

  def send_message
    raise "Not Implemented Yet."
  end

  def add_permission(options={})
    raise "no target queue specified" unless options[:queue]
    raise "no permissions objects specified" unless options[:permissions]

    [options[:permissions]].flatten.each_with_index do |perm, index|
      ordinal = index+1
      options.merge!(perm.to_params(ordinal)) # last label wins.
    end

    options.delete(:permissions)
    options.merge!( :action => "AddPermission" )

    call_amazon(options)
  end

  def remove_permission(options={})
    raise "no target queue specified" unless options[:queue]
    raise "no permissions objects specified" unless options[:permissions]

    [options[:permissions]].flatten.each_with_index do |perm, index|
      ordinal = index+1
      options.merge!(perm.to_params(ordinal)) # last label wins.
    end

    options.delete(:permissions)
    options.merge!( :action => "RemovePermission" )

    call_amazon(options)
  end

  def list_queues(options={})
    prefix = options.delete(:prefix)
    match = options.delete(:match)

    options.merge!( :action => "ListQueues" )
    options.merge!( :queue_name_prefix => encode(prefix) ) if prefix

    call_amazon(options) do |req|
      queues = SQSQueue.parse(req.response)
      queues.select!{|q| q.queue_url.path.match(match) } if match
      queues
    end
  end

  def receive_message(options={})
    raise "no target queue specified" unless options[:queue]
    options = { :max_number_of_messages => 10 }.merge(options)
    options.merge!(:action => "ReceiveMessage")
    call_amazon(options){ |req| SQSMessage.parse(req.response) }
  end

  def delete_message(options={})
    raise "no Message specified" unless options[:message]
    options.merge!(:action => "DeleteMessage", :receipt_handle => options.delete(:message).receipt_handle)
    call_amazon(options)
  end

  def get_queue_attributes(options={})
    raise "no target queue specified" unless options[:queue]
    options = {:attribute_name => "All" }.merge(options)
    options.merge!(:action => "GetQueueAttributes")
    call_amazon(options){ |req| SQSAttributes.parse(req.response) }
  end

  def delete_queue(options={})
    raise "no target queue specified" unless options[:queue]
    options.merge!( :action => "DeleteQueue")
    call_amazon(options)
  end

  def create_queue(options={})
    raise "no queue name specified" unless options[:queue_name]
    options[:default_visibility_timeout] = 30 unless options[:default_visibility_timeout]
    options.merge!( :action => "CreateQueue" )
    call_amazon(options){ |req| SQSQueue.parse(req.response) }
  end

  private

    def call_amazon(options)
      endpoint = (options[:queue] != nil) ? options.delete(:queue).queue_url : "http://" << ( options.delete(:host) || region_host(:us_east) )
      callbacks = options.delete(:callbacks) || {:success=>nil, :failure =>nil }

      options.amazonize_keys!
      params = sign_params( endpoint, options )
      req = EM::HttpRequest.new("#{endpoint}?#{params}").get
      req.callback do |req|
        if(req.response.to_s.match(/<ErrorResponse>/i))
           on_failure(req, callbacks)
        else
          result = req
          result = yield req if block_given?
          callbacks[:success].call(result) if callbacks[:success]
        end
      end
      req.errback do |req|
        on_failure(req, callbacks)
      end
    end

    def on_failure(req, callbacks)
      result = (req.error != nil) ? req.error : req.response
      log result
      callbacks[:failure].call(result) if callbacks[:failure]
    end

    def sign_params(uri, opts)
      uri = URI.parse(uri) if uri.kind_of? String
      opts = default_paramters.merge(opts)

      sorted_params = opts.sort {|x,y| x[0] <=> y[0]}
      encoded_params = sorted_params.collect do |p|
        encode(p[0].to_s) << "=" << encode(p[1].to_s)
      end
      params_string = encoded_params.join("&")

      req_desc = ["GET", uri.host.downcase, uri.request_uri, params_string].join("\n")
      params_string << "&Signature=" << generate_signature(req_desc)
    end

    def generate_signature(request_description)
      hmac = HMAC::SHA256.new(aws_secret)
      hmac.update(request_description)
      encode(Base64.encode64(hmac.digest).chomp)
    end

    def encoding_exclusions
      /[^\w\d\-\_\.\~]/
    end

    def encode(val)
      URI.encode(val, encoding_exclusions)
    end

    def region_host(key)
      regions[key][:uri]
    end

    def regions
      @regions ||= Regions
      @regions
    end

    def default_paramters
      @default_paramters ||= Parameters.merge("AWSAccessKeyId" => aws_key)
      @default_paramters.merge("Expires" => (Time.now+(60*30)).utc.iso8601)
    end

    def post_options
      @post_options ||= PostOptions
      @post_options
    end

    def logger
      return @logger if @logger

      @logger = Logger.new @log_path || "./sqs_async.log"
      @logger.level = @log_level || Logger::WARN
      @logger
    end

    def log(msg)
      log_msg = ["SERVICE ERROR"]
      log_msg << caller[0..7].join("\n\t")
      log_msg << "-".ljust(80, "-")
      log_msg << msg
      log_msg << "-".ljust(80, "-")
      logger.error(log_msg.join("\n"))
    end

    Regions = {
      :us_east => { :name => "US-East (Northern Virginia) Region", :uri  => "sqs.us-east-1.amazonaws.com"},
      :us_west => { :name => "US-West (Northern California) Region", :uri  => "sqs.us-west-1.amazonaws.com"},
      :eu => { :name => "EU (Ireland) Region", :uri  => "sqs.eu-west-1.amazonaws.com"},
      :asia_singapore => { :name => "Asia Pacific (Singapore) Region", :uri  => "sqs.ap-southeast-1.amazonaws.com"},
      :asia_tokyo => { :name => "Asia Pacific (Tokyo) Region", :uri  => "sqs.ap-northeast-1.amazonaws.com"}
    }


    Parameters = {
      "Version" => "2009-02-01",
      "SignatureVersion"=>"2",
      "SignatureMethod"=>"HmacSHA256",
    }

    PostOptions = {
      "Content-Type" => "application/x-www-form-urlencoded"
    }
end
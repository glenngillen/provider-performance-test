require "sinatra"
require "sinatra/synchrony"
require "redis"
require "pg/em"
require "em-synchrony/pg"
require "dalli"
require "active_support/secure_random"

def redis_connection_hash(env)
  uri = URI.parse(env)
  { :host => uri.host, :port => uri.port, :password => uri.password,
    :driver => :synchrony }
end
def constantize(camel_cased_word)
  names = camel_cased_word.split('::')
  names.shift if names.empty? || names.first.empty?

  constant = Object
  names.each do |name|
    constant = constant.const_defined?(name) ? constant.const_get(name) : constant.const_missing(name)
  end
  constant
end
ENV.keys.select{|key| key =~ /REDIS/ }.each do |key|
  const_name = key.sub(/_URL\z/,"")
  Object.const_set const_name, Redis.new(redis_connection_hash(ENV[key]))
end
ENV.keys.select{|key| key =~ /MEMCACH.*_SERVERS/ }.each do |key|
  const_name = key.sub(/_SERVERS\z/,"")
  hosts = ENV["#{const_name}_SERVERS"].split(",")
  servers = hosts.map do |host|
    "memcached://#{ENV["#{const_name}_USERNAME"]}:#{ENV["#{const_name}_PASSWORD"]}@#{host}"
  end
  Object.const_set const_name, Dalli::Client.new(servers,
        :failover => true, :down_retry_delay => 60, :keepalive => true)
end

if ENV["DATABASE_URL"]
  config = URI.parse(ENV["DATABASE_URL"])
  adapter = config.scheme
  spec = { :dbname => config.path.sub(%r{^/},""),
           :host => config.host }
  spec[:user] = config.user if config.user
  spec[:password] = config.password if config.password
  spec[:port] = config.port if config.port
  DB = EM::Synchrony::ConnectionPool.new(size: 10) do
    PG::EM::Client.new(spec)
  end
end

def random_key
  ActiveSupport::SecureRandom.hex(16)
end

def random_value
  ActiveSupport::SecureRandom.hex(16)
end

def redis_test(const)
  key = random_key
  val = random_value
  const.set(key, val)
  (val == const.get(key)).to_s
end

def memcache_test(const)
  key = random_key
  val = random_value
  const.set(key, val)
  (val == const.get(key)).to_s
end

get %r{/(.*redis.*)} do
  const = constantize(params[:captures].first.upcase)
  redis_test(const)
end

get %r{/(.*memcach.*)} do
  const = constantize(params[:captures].first.upcase)
  memcache_test(const)
end

get "/pg" do
  key = random_key
  val = random_value
  DB.query(%Q{insert into cache (key, value) values ('#{key}','#{val}')}) do |inserted|
    DB.query(%Q{select value from cache where key = '#{key}'}) do |result|
      (val == result.getvalue(0,0)).to_s
    end
  end
end

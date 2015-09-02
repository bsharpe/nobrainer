require 'digest/sha1'

class NoBrainer::Lock
  include NoBrainer::Document

  table_config :name => 'nobrainer_locks'

  # Since PKs are limited to 127 characters, we can't use the user's key as a PK
  # as it could be arbitrarily long.
  field :key_hash,       :type => String, :primary_key => true, :default => ->{ Digest::SHA1.base64digest(key.to_s) }
  field :key,            :type => String
  field :instance_token, :type => String, :default => ->{ get_new_instance_token }
  field :expires_at,     :type => Time

  scope :expired, where(:expires_at.lt(RethinkDB::RQL.new.now))

  def initialize(key, options={})
    if options[:from_db]
      super
      # We reset our instance_token to allow recoveries.
      self.instance_token = get_new_instance_token
    else
      super(options.merge(:key => key))
      raise ArgumentError unless valid?
    end
  end

  def get_new_instance_token
    NoBrainer::Document::PrimaryKey::Generator.generate
  end

  def synchronize(options={}, &block)
    lock(options)
    begin
      block.call
    ensure
      unlock if @locked
    end
  end

  def lock(options={})
    options.assert_valid_keys(:expire, :timeout)
    timeout = NoBrainer::Config.lock_options.merge(options)[:timeout]
    sleep_amount = 0.1

    start_at = Time.now
    while Time.now - start_at < timeout
      return if try_lock(options.slice(:expire))
      sleep(sleep_amount)
      sleep_amount = [1, sleep_amount * 2].min
    end

    raise_lock_unavailable!
  end

  def try_lock(options={})
    options.assert_valid_keys(:expire)
    raise_if_locked!

    set_expiration(options)

    result = NoBrainer.run do |r|
      selector.replace do |doc|
        r.branch(doc.eq(nil).or(doc[:expires_at] < r.now),
                 self.attributes, doc)
      end
    end

    return @locked = (result['inserted'] + result['replaced']) == 1
  end

  def unlock
    raise_unless_locked!

    result = NoBrainer.run do |r|
      selector.replace do |doc|
        r.branch(doc[:instance_token].eq(self.instance_token),
                 nil, doc)
      end
    end

    @locked = false
    raise_lost_lock! unless result['deleted'] == 1
  end

  def refresh(options={})
    options.assert_valid_keys(:expire)
    raise_unless_locked!

    set_expiration(options.merge(:use_previous_expire => true))

    result = NoBrainer.run do |r|
      selector.update do |doc|
        r.branch(doc[:instance_token].eq(self.instance_token),
                 { :expires_at => self.expires_at }, nil)
      end
    end

    # Note: If we are too quick, expires_at may not change, and the returned
    # 'replaced' won't be 1. We'll generate a spurious error. This is very
    # unlikely to happen and should not harmful.
    unless result['replaced'] == 1
      @locked = false
      raise_lost_lock!
    end
  end

  def save?(*);  raise NotImplementedError; end
  def delete(*); raise NotImplementedError; end

  private

  def set_expiration(options)
    expire = options[:expire]
    expire ||= @previous_expire if options[:use_previous_expire]
    expire ||= NoBrainer::Config.lock_options[:expire]
    @previous_expire = expire
    self.expires_at = RethinkDB::RQL.new.now + expire
  end

  def raise_if_locked!
    raise NoBrainer::Error::LockInvalidOp.new("Lock instance `#{key}' already locked") if @locked
  end

  def raise_unless_locked!
    raise NoBrainer::Error::LockInvalidOp.new("Lock instance `#{key}' not locked") unless @locked
  end

  def raise_lost_lock!
    raise NoBrainer::Error::LostLock.new("Lost lock on `#{key}'")
  end

  def raise_lock_unavailable!
    raise NoBrainer::Error::LockUnavailable.new("Lock on `#{key}' unavailable")
  end
end

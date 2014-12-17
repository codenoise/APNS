module APNS
  require 'socket'
  require 'openssl'
  require 'json'

  @host = 'gateway.sandbox.push.apple.com'
  @port = 2195
  # openssl pkcs12 -in mycert.p12 -out client-cert.pem -nodes -clcerts
  @pem = nil # this should be the path of the pem file not the contentes
  @pass = nil

  class << self
    attr_accessor :host, :pem, :port, :pass
  end

  def self.send_notification(device_token, message)
    n = APNS::Notification.new(device_token, message)
    self.send_notifications([n])
  end

  def self.send_notifications(notifications)
    sock, ssl = self.open_connection
    bad_notifications = []

    # group notifications in to groups of 10.
    notifications = group_array(notifications, 10, false)
    
    # send out each group as a block request
    notifications.each do |n|
      packed_nofications = self.packed_nofications(n)
      begin
        ssl.write(packed_nofications)

        sleep(0.25) #ensure APNS has time to reply
        err_packet = ssl.read_nonblock(6)

        # should not get here unless apple returns something
        command, errorCode, identifier = err_packet.unpack('CCN');
        puts "Command: #{command} Code: #{errorCode} Identifier: #{identifier}"
        bad_notifications << {error_code:errorCode, notification: (n.find{|n1| n1.message_identifier.unpack('N') == identifier})}
        ssl.close if ssl
        sock.close if sock
        sock, ssl = self.open_connection
      rescue IO::WaitReadable
      rescue Exception => e
        puts "caught an exception: #{e.inspect}"
        ssl.close if ssl
        sock.close if sock
        sock, ssl = self.open_connection
      end
    end

  ensure
    ssl.close if ssl
    sock.close if sock

    bad_notifications || []
  end

  def self.packed_nofications(notifications)
    bytes = ''

    notifications.each do |notification|
      # Each notification frame consists of
      # 1. (e.g. protocol version) 2 (unsigned char [1 byte]) 
      # 2. size of the full frame (unsigend int [4 byte], big endian)
      pn = notification.packaged_notification
      bytes << ([2, pn.bytesize].pack('CN') + pn)
    end

    bytes
  end

  def self.feedback
    sock, ssl = self.feedback_connection

    apns_feedback = []

    while message = ssl.read(38)
      timestamp, token_size, token = message.unpack('N1n1H*')
      apns_feedback << [Time.at(timestamp), token]
    end

    ssl.close
    sock.close

    return apns_feedback
  end

  protected

  def self.open_connection
    raise "The path to your pem file is not set. (APNS.pem = /path/to/cert.pem)" unless self.pem
    raise "The path to your pem file does not exist!" unless File.exist?(self.pem)

    context      = OpenSSL::SSL::SSLContext.new
    context.cert = OpenSSL::X509::Certificate.new(File.read(self.pem))
    context.key  = OpenSSL::PKey::RSA.new(File.read(self.pem), self.pass)

    sock         = TCPSocket.new(self.host, self.port)
    ssl          = OpenSSL::SSL::SSLSocket.new(sock,context)
    ssl.connect

    return sock, ssl
  end

  def self.feedback_connection
    raise "The path to your pem file is not set. (APNS.pem = /path/to/cert.pem)" unless self.pem
    raise "The path to your pem file does not exist!" unless File.exist?(self.pem)

    context      = OpenSSL::SSL::SSLContext.new
    context.cert = OpenSSL::X509::Certificate.new(File.read(self.pem))
    context.key  = OpenSSL::PKey::RSA.new(File.read(self.pem), self.pass)

    fhost = self.host.gsub('gateway','feedback')
    puts fhost

    sock         = TCPSocket.new(fhost, 2196)
    ssl          = OpenSSL::SSL::SSLSocket.new(sock,context)
    ssl.connect

    return sock, ssl
  end
  
  def self.group_array(arr, number, fill_with = nil)
    if fill_with == false
      collection = arr
    else
      # size % number gives how many extra we have;
      # subtracting from number gives how many to add;
      # modulo number ensures we don't add group of just fill.
      padding = (number - size % number) % number
      collection = dup.concat(Array.new(padding, fill_with))
    end

    if block_given?
      collection.each_slice(number) { |slice| yield(slice) }
    else
      collection.each_slice(number).to_a
    end
  end
end

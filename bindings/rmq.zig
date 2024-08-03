pub const rmq = @cImport({
    @cInclude("amqp.h");
    @cInclude("amqp_tcp_socket.h");
    @cInclude("amqp_ssl_socket.h");
    @cInclude("amqp_framing.h");
});

test {
    _ = rmq;
}

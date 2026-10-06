#!/usr/bin/env python3
"""Small, exact-source instrumentation of cloudflare/quiche's existing apps."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
here = pathlib.Path(__file__).resolve().parent


def change(path, old, new, count=1):
    file = root / path
    text = file.read_text()
    actual = text.count(old)
    if actual != count:
        raise RuntimeError(f"{path}: expected {count} patch anchors, found {actual}: {old[:80]}")
    file.write_text(text.replace(old, new), newline="\n")


change("apps/src/lib.rs", "pub mod client;", "pub mod client;\npub mod bench;")
(root / "apps/src/bench.rs").write_text((here / "bench.rs").read_text(), newline="\n")
change("quiche/src/lib.rs", "    pub fn peer_cert(&self) -> Option<&[u8]> {",
       '    pub fn benchmark_cipher(&self) -> Option<String> {\n'
       '        self.handshake.cipher().map(|cipher| format!("{cipher:?}"))\n'
       '    }\n\n    pub fn peer_cert(&self) -> Option<&[u8]> {')
change("apps/src/client.rs", "    let mut out = [0; MAX_DATAGRAM_SIZE];",
       "    let mut out = [0; 1472];\n    crate::bench::initialize();")
change("apps/src/client.rs", "const MAX_DATAGRAM_SIZE: usize = 1350;\n", "")
change("apps/src/client.rs", "        mio::net::UdpSocket::bind(bind_addr.parse().unwrap()).unwrap();",
       "        mio::net::UdpSocket::bind(bind_addr.parse().unwrap()).unwrap();\n"
       "    crate::bench::configure_socket(&socket)\n"
       "        .map_err(|e| ClientError::Other(format!(\"socket configuration failed: {e}\")))?;", count=2)
change("apps/src/client.rs", "socket.recv_from(&mut buf)", "crate::bench::recv_from(socket, &mut buf)")
change("apps/src/client.rs", "config.set_max_recv_udp_payload_size(MAX_DATAGRAM_SIZE);",
       "config.set_max_recv_udp_payload_size(crate::bench::max_udp_payload());")
change("apps/src/client.rs", "config.set_max_send_udp_payload_size(MAX_DATAGRAM_SIZE);",
       "config.set_max_send_udp_payload_size(crate::bench::max_udp_payload());")
# The upstream TLS configuration's default is peer verification; make it explicit.
change("apps/src/client.rs", "    config.set_application_protos(&conn_args.alpns).unwrap();",
       "    config.verify_peer(!args.no_verify);\n"
       "    assert!(!crate::bench::enabled() || (!args.no_verify && !conn_args.early_data));\n"
       "    config.set_application_protos(&conn_args.alpns).unwrap();")
# Limit timer sleep, without replacing the upstream UDP or recovery event loop.
text = (root / "apps/src/client.rs").read_text()
anchor = "    loop {\n"
position = text.find(anchor, text.find("let mut http_conn"))
if position < 0:
    raise RuntimeError("client event loop anchor missing")
text = text[:position] + text[position:].replace(anchor,
    "    loop {\n"
    "        if crate::bench::finished() {\n"
    "            crate::bench::finish(&conn).map_err(ClientError::Other)?;\n"
    "            conn.close(true, 0x100, b\"benchmark complete\").ok();\n"
    "            if let Ok((len, info)) = conn.send(&mut out) {\n"
    "                socket.send_to(&out[..len], info.to)\n"
    "                    .map_err(|e| ClientError::Other(format!(\"close send failed: {e}\")))?;\n"
    "            }\n"
    "            return Ok(());\n"
    "        }\n", 1)
(root / "apps/src/client.rs").write_text(text, newline="\n")
change("apps/src/client.rs", "poll.poll(&mut events, conn.timeout())",
       "poll.poll(&mut events, if crate::bench::enabled() {\n"
       "            Some(conn.timeout().unwrap_or(std::time::Duration::from_millis(10))\n"
       "                .min(std::time::Duration::from_millis(10)))\n"
       "        } else { conn.timeout() })")
change("apps/src/common.rs", '                        debug!(\n'
       '                            "got {read} bytes of response data on stream {stream_id}"',
       '                        crate::bench::received(read);\n'
       '                        debug!(\n'
       '                            "got {read} bytes of response data on stream {stream_id}"')
change("apps/src/common.rs", "if !self.dump_json {",
       "if !self.dump_json && !crate::bench::enabled() {", count=1)
change("apps/src/common.rs", "body.len().to_string().as_bytes(),\n            ),\n        ];",
       '(if crate::bench::server_enabled() { 1u64 << 50 } else { body.len() as u64 })\n'
       '                    .to_string().as_bytes(),\n            ),\n        ];')
change("apps/src/common.rs",
       "self.h3_conn.send_body(conn, stream_id, body, true)",
       "self.h3_conn.send_body(conn, stream_id, body, !crate::bench::server_enabled())")
change("apps/src/common.rs",
       "        if resp.written == resp.body.len() {\n            partial_responses.remove(&stream_id);\n        }",
       "        if resp.written == resp.body.len() {\n"
       "            if crate::bench::server_enabled() {\n"
       "                resp.written = 0;\n"
       "            } else {\n"
       "                partial_responses.remove(&stream_id);\n"
       "            }\n"
       "        }", count=2)
change("apps/src/bin/quiche-server.rs", "    let max_datagram_size = MAX_DATAGRAM_SIZE;",
       "    let max_datagram_size = quiche_apps::bench::max_udp_payload();")
change("apps/src/bin/quiche-server.rs", "const MAX_DATAGRAM_SIZE: usize = 1350;\n", "")
change("apps/src/bin/quiche-server.rs", "        mio::net::UdpSocket::bind(args.listen.parse().unwrap()).unwrap();",
       "        mio::net::UdpSocket::bind(args.listen.parse().unwrap()).unwrap();\n"
       "    quiche_apps::bench::configure_socket(&socket).expect(\"socket configuration failed\");")
change("apps/src/bin/quiche-server.rs", '    trace!("GSO detected: {enable_gso}");',
       '    trace!("GSO detected: {enable_gso}");\n'
       '    println!("QUICHE_SERVER_SETTINGS={{\\"gso_enabled\\":{enable_gso},'
       '\\"pacing_enabled\\":{pacing},\\"max_udp_payload\\":{max_datagram_size}}}");')
# Upstream ties UDP_SEGMENT sendmsg to SO_TXTIME. Allow software GSO without pacing.
change("apps/src/sendto.rs",
       "    segment_size: usize,\n) -> io::Result<usize> {",
       "    segment_size: usize, pacing: bool,\n) -> io::Result<usize> {", count=1)
change("apps/src/sendto.rs", "    match sendmsg(\n",
       "    let messages = if pacing { vec![cmsg_gso, cmsg_txtime] } else { vec![cmsg_gso] };\n"
       "    match sendmsg(\n")
change("apps/src/sendto.rs", "&[cmsg_gso, cmsg_txtime],", "&messages,")
change("apps/src/sendto.rs",
       "    if pacing && enable_gso {\n        match send_to_gso_pacing(socket, buf, send_info, segment_size) {",
       "    if enable_gso {\n        match send_to_gso_pacing(socket, buf, send_info, segment_size, pacing) {")
# Linux is the only supported benchmark platform; make actual segmentation visible.
change("apps/src/sendto.rs", "                return Ok(v);",
       "                GSO_SENDS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);\n"
       "                return Ok(v);")
with (root / "apps/src/sendto.rs").open("a", newline="\n") as file:
    file.write("\npub static GSO_SENDS: std::sync::atomic::AtomicU64 = "
               "std::sync::atomic::AtomicU64::new(0);\n")
change("apps/src/bin/quiche-server.rs",
       '    let mut continue_write = false;',
       '    let mut continue_write = false;\n'
       '    let mut benchmark_report = std::time::Instant::now();')
change("apps/src/bin/quiche-server.rs", "        // Find the shorter timeout",
       "        if benchmark_report.elapsed().as_secs() >= 1 {\n"
       '            println!("QUICHE_GSO_SENDS={}", GSO_SENDS.load(std::sync::atomic::Ordering::Relaxed));\n'
       "            benchmark_report = std::time::Instant::now();\n"
       "        }\n        // Find the shorter timeout")
# The example stops after the first connection fills a send burst. During an
# endless benchmark body, that permanently starves later HashMap entries.
change("apps/src/bin/quiche-server.rs",
       '                continue_write = true;\n                break;\n',
       '                continue_write = true;\n'
       '                if quiche_apps::bench::server_enabled() { continue; }\n'
       '                break;\n')
print("QUICHE_INSTRUMENTED")

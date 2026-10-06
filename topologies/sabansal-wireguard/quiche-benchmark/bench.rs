use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static BYTES: AtomicU64 = AtomicU64::new(0);
static FIRST_BYTE: OnceLock<Instant> = OnceLock::new();
static CLOCK: OnceLock<(Instant, Instant)> = OnceLock::new();
static ENABLED: OnceLock<bool> = OnceLock::new();
static SERVER_ENABLED: OnceLock<bool> = OnceLock::new();
static GRO_BATCHES: AtomicU64 = AtomicU64::new(0);
static RECV_CALLS: AtomicU64 = AtomicU64::new(0);

pub fn enabled() -> bool {
    *ENABLED.get_or_init(|| std::env::var_os("QUICHE_BENCH_START_NS").is_some())
}

pub fn server_enabled() -> bool {
    *SERVER_ENABLED.get_or_init(|| std::env::var_os("QUICHE_BENCH_SERVER").is_some())
}

pub fn configure_socket(socket: &mio::net::UdpSocket) -> std::io::Result<()> {
    use nix::sys::socket::{setsockopt, sockopt};
    use std::os::fd::AsFd;
    setsockopt(&socket.as_fd(), sockopt::RcvBuf, &(16usize << 20))?;
    setsockopt(&socket.as_fd(), sockopt::SndBuf, &(16usize << 20))?;
    if enabled() && std::env::var("QUICHE_BENCH_GRO").as_deref() != Ok("0") {
        setsockopt(&socket.as_fd(), sockopt::UdpGroSegment, &true)?;
    }
    Ok(())
}

struct ReceiveBatch {
    data: Vec<u8>,
    offset: usize,
    end: usize,
    segment: usize,
    peer: std::net::SocketAddr,
}

thread_local! {
    static BATCH: std::cell::RefCell<ReceiveBatch> = std::cell::RefCell::new(ReceiveBatch {
        data: vec![0; 65535], offset: 0, end: 0, segment: 0,
        peer: "0.0.0.0:0".parse().unwrap(),
    });
}

// Preserve the upstream single-datagram event loop while unbatching Linux GRO.
pub fn recv_from(socket: &mio::net::UdpSocket, buffer: &mut [u8])
    -> std::io::Result<(usize, std::net::SocketAddr)>
{
    use nix::sys::socket::{recvmsg, ControlMessageOwned, MsgFlags, SockaddrStorage};
    use std::io::{Error, ErrorKind, IoSliceMut};
    use std::os::fd::AsRawFd;
    BATCH.with(|batch| {
        let mut batch = batch.borrow_mut();
        if batch.offset == batch.end {
            let mut control = nix::cmsg_space!(u32);
            let (bytes, peer, segment) = {
                let mut slices = [IoSliceMut::new(&mut batch.data)];
                let message = recvmsg::<SockaddrStorage>(
                    socket.as_raw_fd(), &mut slices, Some(&mut control), MsgFlags::empty(),
                )?;
                if message.flags.intersects(MsgFlags::MSG_TRUNC | MsgFlags::MSG_CTRUNC) {
                    return Err(Error::new(ErrorKind::InvalidData, "truncated UDP GRO batch"));
                }
                let address = message.address.ok_or_else(|| Error::new(ErrorKind::InvalidData, "missing UDP peer"))?;
                let address = address.as_sockaddr_in().ok_or_else(|| Error::new(ErrorKind::InvalidData, "benchmark requires IPv4"))?;
                let peer = std::net::SocketAddr::V4(std::net::SocketAddrV4::new(address.ip(), address.port()));
                let mut segment = message.bytes;
                for control in message.cmsgs()? {
                    if let ControlMessageOwned::UdpGroSegments(size) = control {
                        segment = size as usize;
                        GRO_BATCHES.fetch_add(1, Ordering::Relaxed);
                    }
                }
                (message.bytes, peer, segment)
            };
            if bytes == 0 || segment == 0 {
                return Err(Error::new(ErrorKind::InvalidData, "empty UDP datagram"));
            }
            RECV_CALLS.fetch_add(1, Ordering::Relaxed);
            batch.offset = 0;
            batch.end = bytes;
            batch.segment = segment;
            batch.peer = peer;
        }
        let length = batch.segment.min(batch.end - batch.offset);
        if length > buffer.len() {
            return Err(Error::new(ErrorKind::InvalidData, "receive buffer too small"));
        }
        buffer[..length].copy_from_slice(&batch.data[batch.offset..batch.offset + length]);
        batch.offset += length;
        Ok((length, batch.peer))
    })
}

pub fn max_udp_payload() -> usize {
    let value = std::env::var("QUICHE_BENCH_MAX_UDP")
        .unwrap_or_else(|_| "1350".into())
        .parse::<usize>()
        .expect("invalid QUICHE_BENCH_MAX_UDP");
    assert!((1200..=1472).contains(&value), "IPv4 UDP payload must be 1200..1472");
    value
}

fn clock() -> &'static (Instant, Instant) {
    CLOCK.get_or_init(|| {
        let epoch = std::env::var("QUICHE_BENCH_START_NS")
            .expect("missing start timestamp")
            .parse::<u128>()
            .expect("invalid start timestamp");
        let duration = std::env::var("QUICHE_BENCH_DURATION")
            .expect("missing duration")
            .parse::<u64>()
            .expect("invalid duration");
        assert!(duration > 0);
        let now = Instant::now();
        let epoch_now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        assert!(epoch > epoch_now, "benchmark launched after measurement start");
        let start = now + Duration::from_nanos(u64::try_from(epoch - epoch_now).unwrap());
        (start, start + Duration::from_secs(duration))
    })
}

pub fn initialize() {
    if enabled() {
        clock();
    }
}

pub fn received(bytes: usize) {
    if !enabled() {
        return;
    }
    let now = Instant::now();
    FIRST_BYTE.get_or_init(|| now);
    let (start, end) = *clock();
    if now >= start && now < end {
        BYTES.fetch_add(bytes as u64, Ordering::Relaxed);
    }
}

pub fn finished() -> bool {
    enabled() && Instant::now() >= clock().1
}

pub fn finish(conn: &quiche::Connection) -> Result<(), String> {
    let bytes = BYTES.load(Ordering::Relaxed);
    let (start, end) = *clock();
    let first = FIRST_BYTE.get().ok_or("no HTTP/3 body received")?;
    if *first >= start {
        return Err("connection did not transfer body during warmup".into());
    }
    if bytes == 0 || !conn.is_established() || conn.is_in_early_data() ||
        conn.application_proto() != b"h3" || conn.peer_cert().is_none()
    {
        return Err("missing encrypted, established HTTP/3 transfer".into());
    }
    let seconds = (end - start).as_secs_f64();
    let cipher = conn.benchmark_cipher().ok_or("missing negotiated cipher")?;
    let stats = conn.stats();
    println!(
        "QUICHE_RESULT={{\"bytes_received\":{bytes},\"duration_seconds\":{seconds},\
         \"bits_per_second\":{},\"cipher\":\"{cipher}\",\"alpn\":\"h3\",\
         \"tls_version\":\"TLSv1.3\",\"early_data\":false,\"certificate_verified\":true,\
         \"warmup_received_seconds\":{},\"transport_recv_bytes\":{},\
         \"transport_sent_bytes\":{},\"lost_packets\":{},\"udp_receive_calls\":{},\
         \"gro_batches_received\":{}}}",
        bytes as f64 * 8.0 / seconds,
        (start - *first).as_secs_f64(),
        stats.recv_bytes, stats.sent_bytes, stats.lost,
        RECV_CALLS.load(Ordering::Relaxed), GRO_BATCHES.load(Ordering::Relaxed),
    );
    Ok(())
}

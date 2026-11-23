//! The paced read of an upload, so that a screen examination can show an upload under way.

use std::io::Read;

/// Keeps the kernel from taking much more of a body than the server has read, so the client's count
/// of bytes sent follows the paced read: on loopback the buffers otherwise grow to megabytes, and a
/// whole scan counts as sent at once. Each accepted connection inherits the listener's buffer.
pub fn limit_receive_buffer(listener: &std::net::TcpListener, bytes: usize) {
    use std::os::fd::AsRawFd;
    let size = libc::c_int::try_from(bytes.max(1024)).unwrap_or(libc::c_int::MAX);
    // SAFETY: the descriptor is the listener's own, open for the whole call, and the option value is
    // a c_int whose size is passed with it.
    let result = unsafe {
        libc::setsockopt(
            listener.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            std::ptr::from_ref(&size).cast(),
            libc::socklen_t::try_from(size_of::<libc::c_int>()).unwrap_or(4),
        )
    };
    assert_eq!(result, 0, "the receive buffer of the listener can be set");
}

/// Reads a body whole, or at `pace` bytes per second, a tenth of a second at a time.
pub fn read_body(reader: &mut dyn Read, pace: Option<usize>, body: &mut Vec<u8>) -> std::io::Result<()> {
    let Some(pace) = pace else {
        return reader.read_to_end(body).map(|_| ());
    };
    let mut chunk = vec![0; (pace / 10).max(1)];
    loop {
        let read = reader.read(&mut chunk)?;
        if read == 0 {
            return Ok(());
        }
        body.extend_from_slice(&chunk[..read]);
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

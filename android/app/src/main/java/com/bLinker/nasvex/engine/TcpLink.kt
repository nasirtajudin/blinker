package com.bLinker.nasvex.engine

import android.net.Network
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Raw TCP link layer - the transport every file byte will flow over.
 *
 * Phase 3 layers the manifest-first protocol (file table header, streamed
 * bodies, SHA-256, resume markers) on exactly these sockets; nothing here is
 * throwaway.
 *
 * Server side enforces the single-client policy: the FIRST accepted socket is
 * THE partner, every later connection is closed immediately.
 */
object TcpLink {

    const val PORT = 58231

    private val pool: ExecutorService = Executors.newCachedThreadPool { r ->
        Thread(r, "bLinker-tcp").apply { isDaemon = true }
    }

    /**
     * Socket tuning. SO_RCVBUF/SO_SNDBUF are deliberately left alone: a fixed
     * value disables the kernel's auto-tuning and would cap throughput.
     */
    fun tune(socket: Socket) {
        socket.tcpNoDelay = true
        socket.keepAlive = true
    }

    class Server(private val bus: EngineBus) {
        @Volatile var client: Socket? = null
            private set
        private var server: ServerSocket? = null

        fun listen(onClient: (Socket) -> Unit, onFailed: (String) -> Unit) {
            pool.execute {
                try {
                    val s = ServerSocket()
                    s.reuseAddress = true
                    s.bind(InetSocketAddress(PORT))
                    server = s
                    bus.emit("tcp:listening", JSONObject().put("port", PORT))
                    while (!s.isClosed) {
                        val c = s.accept()
                        if (client != null) {
                            runCatching { c.close() }   // single-client policy
                            continue
                        }
                        client = c
                        tune(c)
                        onClient(c)
                    }
                } catch (t: Throwable) {
                    if (server?.isClosed != true) onFailed(t.message ?: "listen failed")
                }
            }
        }

        fun stop() {
            runCatching { server?.close() }
            runCatching { client?.close() }
            server = null
            client = null
        }
    }

    class Client(private val bus: EngineBus) {
        @Volatile var socket: Socket? = null
            private set

        fun connect(host: String, port: Int, network: Network?,
                    onConnected: (Socket) -> Unit, onFailed: (String) -> Unit) {
            pool.execute {
                try {
                    // CRITICAL: bind to the Wi-Fi network. Without this the OS
                    // routes 192.168.x.x over cellular and the connect hangs.
                    val s = Net.socketFor(network)
                    tune(s)
                    s.connect(InetSocketAddress(host, port), 12_000)
                    socket = s
                    onConnected(s)
                } catch (t: Throwable) {
                    onFailed(t.message ?: "connect failed")
                }
            }
        }

        fun stop() {
            runCatching { socket?.close() }
            socket = null
        }
    }
}

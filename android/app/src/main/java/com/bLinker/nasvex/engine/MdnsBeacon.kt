package com.bLinker.nasvex.engine

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import org.json.JSONObject

/**
 * Method (1) of the waterfall: both devices on the SAME router.
 * The receiver advertises "_blinker._tcp" and the sender browses for it -
 * zero prompts, zero hotspots, straight over the LAN (fastest path).
 */
@Suppress("DEPRECATION")
class MdnsBeacon(private val context: Context, private val bus: EngineBus) {

    companion object { const val TYPE = "_blinker._tcp." }

    private val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private val resolving = HashSet<String>()

    /** Receiver: advertise this device + its TCP port on the local network. */
    fun advertise(name: String, port: Int) {
        stop()
        val info = NsdServiceInfo()
        info.serviceName = name
        info.serviceType = TYPE
        info.port = port
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                bus.emit("mdns:registered", JSONObject().put("name", serviceInfo.serviceName))
            }
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                bus.emit("mdns:error", JSONObject().put("stage", "register").put("code", errorCode))
            }
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }
        registration = listener
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    /** Sender: browse the local network for receivers. */
    fun browse() {
        stopDiscovery()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                bus.emit("mdns:error", JSONObject().put("stage", "discover").put("code", errorCode))
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName ?: return
                synchronized(resolving) { if (!resolving.add(name)) return }
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                        synchronized(resolving) { resolving.remove(name) }
                    }
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        val host = info.host?.hostAddress ?: return
                        bus.emit("mdns:found", JSONObject()
                            .put("name", info.serviceName)
                            .put("host", host)
                            .put("port", info.port))
                    }
                })
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                serviceInfo.serviceName?.let { n -> synchronized(resolving) { resolving.remove(n) } }
            }
        }
        discovery = listener
        nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun stopDiscovery() {
        discovery?.let { l -> runCatching { nsd.stopServiceDiscovery(l) } }
        discovery = null
    }

    fun stop() {
        stopDiscovery()
        registration?.let { l -> runCatching { nsd.unregisterService(l) } }
        registration = null
    }
}

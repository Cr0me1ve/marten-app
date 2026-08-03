package app.marten.client.ktx

import android.net.IpPrefix
import android.os.Build
import androidx.annotation.RequiresApi
import app.marten.core.libbox.RoutePrefix
import app.marten.core.libbox.StringIterator
import app.marten.core.libbox.StringBox
import java.net.InetAddress

val StringBox?.unwrap: String
get() {
    if (this == null) return ""
    return value
}

fun StringIterator.toList(): List<String> {
    return mutableListOf<String>().apply {
        while (hasNext()) {
            add(next())
        }
    }
}

@RequiresApi(Build.VERSION_CODES.TIRAMISU)
fun RoutePrefix.toIpPrefix() = IpPrefix(InetAddress.getByName(address()), prefix())
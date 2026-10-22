package app.marten.client.bg;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
interface ICorePlatform {
    Bundle call(in Bundle request);
    ParcelFileDescriptor openTun(in Bundle options);
}

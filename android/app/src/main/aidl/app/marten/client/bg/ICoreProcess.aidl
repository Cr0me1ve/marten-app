package app.marten.client.bg;
import android.os.Bundle;
import app.marten.client.bg.ICoreResult;
interface ICoreProcess {
    int pid();
    oneway void submit(in Bundle request, ICoreResult result);
}

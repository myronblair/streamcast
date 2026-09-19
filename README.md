# streamcast

Windows setup script that captures a PC's audio and multicasts it as RTP to a Viking paging horn.

`Install-StreamcastPipeline.ps1` installs and configures:

- GStreamer, via MSYS2/pacman (or from a local `pacman-packages` folder next to the script for a fully offline install)
- an NSSM service, `StreamcastGStreamer`, that runs the pipeline
- a self-elevating control panel `.bat` on the Public Desktop

## Pipeline

```
wasapi2src ! audioconvert ! audioresample
! alawenc
! rtppcmapay min-ptime=20000000 max-ptime=20000000 mtu=172
! udpsink host=239.1.1.50 port=5004 auto-multicast=true ttl-mc=1 bind-address=<voice-VLAN NIC IP>
```

- G.711 **A-law**, 20 ms packets, `mtu=172`, matching Viking's own example command. u-law with 50 ms packets sounded distorted, and buffering changes did not fix it.
- `bind-address` must be the IP of the NIC on the horn's network. Without it Windows sends the multicast out the default route, and GStreamer reports no error.

## Manual steps

Two steps can't be scripted: logging into the streaming service in a browser, and setting that app's output device to the virtual cable (Settings > Sound > Volume mixer).

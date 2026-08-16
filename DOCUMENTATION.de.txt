UDPSVC.R4X
==========

UDPSVC.R4X ist der UDP-Socket-Broker-Service.

Seit 0.53.21 kann R4NET strukturierte UDP-Serviceoperationen als
`NetSocketRequest` ueber R4SYS-`ioServiceCall` starten, pollen, warten und
schliessen. Die normalen R4NET-UDP-Sync-Helfer nutzen intern denselben
Completion-Pfad; `UDPSVC.R4X` bleibt Besitzer von Socket-, Queue-,
Portbindungs- und Restart-Cleanup-Policy.

Projektstruktur seit 0.51.19:
- `build.zig` baut den Service als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports, Startdaten und Contract.

Build:

    cd Code\System\Services\UdpService
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Services\UdpService\zig-out\UDPSVC.R4X

Contract:
- R4XStart-Entry: `udpsvc_main`
- App-Klasse: `service`
- R4L-Imports: `R4SYS`, `R4NET`
- Service-Name: `UDPSVC`
- Standardargumente: `/RUN`
- Zielpfad im Image: `C:\R4OS\SERVICES\UDPSVC.R4X`

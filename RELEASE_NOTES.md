# SafeEject v1.0.0

## English

SafeEject v1.0.0 turns the original PowerShell utility into a user-friendly Windows executable for safely removing external SSDs and USB storage devices.

Highlights:

- Windows executable launcher with administrator elevation
- USB disk selection UI
- Safe eject through Windows Configuration Manager APIs
- Restart Manager process detection
- Volume dismount by drive letter and volume GUID
- Offline fallback for stubborn SSD/UASP devices
- Hardware removal fallback after offline
- Recovery flow for disks that reconnect offline
- Drive-letter restoration when Windows mounts the volume without a letter

## Turkce

SafeEject v1.0.0, harici SSD ve USB diskleri guvenle cikarmak icin hazirlanmis Windows exe surumudur.

One cikanlar:

- Yonetici izni isteyen Windows exe launcher
- USB disk secim ekrani
- Windows Configuration Manager API ile guvenli cikarma
- Diski kullanan uygulamalari tespit etme
- Surucu harfi ve volume GUID ile dismount
- Inatci SSD/UASP diskler icin offline fallback
- Offline sonrasi donanim kaldirma fallback’i
- Tekrar takilinca offline kalan diskleri online yapma
- Harfsiz baglanan volume icin surucu harfi geri verme

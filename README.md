# LowTide

데이터나 배터리가 부족할 때 macOS 앱을 자동으로 종료하고, 상황이 끝나면 다시 실행하는 메뉴바 앱입니다.

*A macOS menu bar app that quits chosen apps on limited networks (Low Data Mode, metered, iPhone hotspot) or on battery, and relaunches them when conditions return to normal.*

## 왜 만들었나

Wi-Fi가 저데이터 모드면 iCloud는 동기화를 멈춥니다. 그런데 Google Drive와 OneDrive는 그대로 동기화를 계속해요. 회사 공유 드라이브는 폴더 목록만 받아와도 몇 시간에 10~20GB를 쓰기 때문에, 핫스팟에 연결하면 하루 만에 데이터를 다 써버립니다. 두 클라이언트 모두 "저데이터일 때 일시정지" 같은 옵션이 없어서, 그 상황에서는 아예 꺼버리는 앱을 만들었습니다.

## 동작

| 규칙 | 조건 | 기본 대상 |
|---|---|---|
| 제한 네트워크 | 주 경로가 저데이터 모드, 종량제 네트워크, 아이폰 핫스팟(라우터 `172.20.10.1`) 중 하나 | Google Drive, OneDrive |
| 배터리 | 전원이 배터리 | Silicon Scope |

- 두 규칙의 대상 앱은 메뉴에서 추가하거나 뺄 수 있습니다.
- 조건이 풀리면 **LowTide가 직접 종료한 앱만** 다시 실행합니다.
- 차단 중에 대상 앱이 다시 켜지면 바로 종료합니다. 로그인 항목으로 켜지는 경우도 포함입니다.
- 네트워크 전환이나 충전기 접촉 불량으로 상태가 잠깐 흔들려도 반응하지 않도록, 3초간 지켜본 뒤에 판단합니다.
- 업로드 대기 확인창 등으로 10초 안에 안 꺼지는 앱은 강제로 종료합니다.
- OneDrive는 별도 동기화 엔진(`OneDrive Sync Service`)까지 같이 종료합니다.

판단 기준은 **실제로 트래픽이 나가는 주 경로**입니다. 유선랜이 꽂혀 있으면 Wi-Fi가 저데이터 모드여도 차단하지 않습니다. 메뉴의 `주 경로`와 `Wi-Fi` 줄에서 현재 판단 근거를 볼 수 있습니다.

## 설치

[Releases](https://github.com/colaH16/LowTide/releases)에서 `LowTide-<버전>-arm64.zip`을 받아 압축을 풀고, `LowTide.app`을 `/Applications`로 옮기면 됩니다. Developer ID로 서명하고 Apple 공증을 받은 빌드입니다.

- 요구 사항: macOS 13 이상, Apple Silicon
- 로그인할 때 자동으로 켜려면 메뉴에서 **로그인 시 실행**을 체크하세요.

## 빌드

Xcode 없이 Command Line Tools만 있으면 됩니다.

```bash
./build.sh            # build/LowTide.app (ad-hoc 서명)
./build.sh install    # /Applications 에 설치하고 실행
./build.sh release    # Developer ID 서명 + 공증 → dist/LowTide-<버전>-arm64.zip
```

`release`는 `SIGN_IDENTITY`(Developer ID Application 인증서)와 `NOTARY_PROFILE`(`xcrun notarytool store-credentials`로 저장한 프로필) 환경변수를 사용합니다.

## 라이선스

MIT

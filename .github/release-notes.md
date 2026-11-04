**Install:** download `Contrail-<version>.dmg` (or the `.zip`) and drag **Contrail** into **Applications**.

**Or with Homebrew:**

```sh
brew install --cask Kiril-P/tap/contrail
```

**Contrail isn't notarized yet**, so macOS blocks the first launch:

1. Open Contrail. When macOS says it can't verify the app, click **Done**.
2. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Contrail message.
3. Confirm with your password or Touch ID, then click **Open**.

You only need to do this once. From 0.4 on, Contrail checks for updates itself and installs them when you choose. Updates are verified with Contrail's signing key. You can check your download against `SHA256SUMS.txt`.

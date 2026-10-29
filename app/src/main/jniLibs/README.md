# proot 二进制放这里

Android 10+ 有一条硬规则：App 不能 `exec` 自己数据目录里的文件（W^X / SELinux `app_data_file`），
唯一保证可执行的目录是 APK 的 native library 目录，而且只接受 `lib*.so` 命名。
所以 proot 这个可执行程序必须改名成 `.so` 混进来——Termux、UserLAnd 都是这么干的。

需要四个文件（都由 `tools/fetch-proot.py` 自动下载并改名）：

```
app/src/main/jniLibs/arm64-v8a/
  libproot.so             ← proot 可执行文件本身
  libproot-loader.so      ← proot 的 guest loader（和 proot 必须同一构建）
  libtalloc.so            ← proot 的动态依赖（DT_NEEDED 写的是 libtalloc.so.2）
  libandroid-shmem.so     ← proot 的动态依赖
```

- 自动获取：`python3 tools/fetch-proot.py`（需要 python3 + 网络，从 packages.termux.dev 取 aarch64 deb 拆包）
- 手动放：从 Termux 官方 deb 或静态构建里取，改名后放进来即可

**许可**：proot 是 GPL-2.0，libtalloc 是 LGPL-3.0。分发 APK 时需同时提供对应源码
（https://github.com/termux/proot 、 https://www.samba.org/ftp/talloc/）。

缺这四个文件时 App 能装能开，但会提示「缺少 proot」，部署跑不起来。

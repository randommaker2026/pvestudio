# 待办

两项已完成的记录留着是为了说明**为什么这么设计**，避免以后有人"简化"掉。

## ✅ 1. `bootstrap.sh` 自动推导网络参数

**原来的问题**：`conf.env` 里 `GATEWAY` / `DNS` / `SEARCH_DOMAIN` / `IP_POOL` /
`BUILD_IP` 全写死成本机网段，换一台 PVE 就全错。而 `bootstrap.sh` 当时只做检查
（网段不符就 warn），不修复 —— 失败方式是 VM 拿了个连不通的地址，很隐蔽。

**现在的做法**：

- `conf.env` 里加 `AUTO_DERIVE="GATEWAY DNS SEARCH_DOMAIN IP_POOL BUILD_IP"`
- `bootstrap.sh` 第 2 步按本机网桥推导并写回 `conf.env`
- **想钉死某个值，就把它从 `AUTO_DERIVE` 里删掉** —— 这样"哪些自动、哪些手动"
  一目了然，也不用在脚本里维护一份出厂默认值表（那种表迟早和 conf.env 脱节）
- `--check` 只读预览，标出「待写入」的项

**推导规则**：

| 键 | 来源 |
|---|---|
| `GATEWAY` | 网桥同网段的默认网关；取不到用该网段第一个地址 |
| `DNS` | `resolv.conf` 第一个非 CGNAT 的 IPv4 nameserver；取不到用 `GATEWAY` |
| `SEARCH_DOMAIN` | `resolv.conf` 的 search 域，跳过 `*.ts.net` |
| `IP_POOL` | 网桥网段可用地址，跳过前后各 10 个，最多 100 个 |
| `BUILD_IP` | `IP_POOL` 的第一个 |

### ⚠️ 千万别去掉 CGNAT 过滤

本机装了 Tailscale，`/etc/resolv.conf` 里是：

```
nameserver 100.100.100.100              ← MagicDNS，在 CGNAT 100.64.0.0/10 内
search taila5f454.ts.net randommaker.local
```

`100.100.100.100` **只有装了 Tailscale 的主机能访问**。直接下发给 VM 的话，
guest 没装 Tailscale 就用不了这个 DNS —— 症状是"能 ping 通 IP 但域名一个都解析不了"，
排查起来很费时间。所以 `lib/common.sh` 里的 `is_cgnat()` 和 `is_ts_domain()`
必须保留。

本机实测结果：`DNS` 回退到网关 `192.168.0.1`，`SEARCH_DOMAIN` 取到 `randommaker.local`。

## ✅ 2. `./make-dist.sh` 同步派生产物

**原来的问题**：`conf.env.example` 和 `reference/*` 是手工 `sed` / `cp` 出来的，
仓库里没有脚本能重新生成。改了 `conf.env` 之后 example 就和现实脱节，而且
**没人会注意到**。

**现在的做法**：`make-dist.sh` 一次生成三个文件并脱敏：

| 文件 | 来源 |
|---|---|
| `conf.env.example` | `conf.env`（替换 `CI_PASSWORD` 和 SSH 密钥路径） |
| `reference/expected-9000.conf` | `/etc/pve/qemu-server/9000.conf`（`cipassword`/`sshkeys` → `<hidden>`） |
| `reference/expected-node-config` | `/etc/pve/nodes/<node>/config` |

```
./make-dist.sh            # 生成 + 自动提交
./make-dist.sh --check    # 只看有没有过期（严格只读）
./make-dist.sh --no-commit
```

两个实现上的坑，都是我自己踩的：

1. `--check` 必须**严格只读**。第一版在"有过期"时也 `cp` 了文件，于是退出码说
   "已过期"但文件其实已经被改掉了。
2. 提交判据要看**和 git HEAD 是否一致**，不是"本次有没有写过文件"。第二版用后者，
   结果文件早被别处改对了但还没提交时，它说"无需改动"就走了。

## 仍然待办

- [ ] **配 PVE 备份任务**。`/etc/pve/jobs.cfg` 目前是空的 —— 模板能重建，
      但跑起来的数据 VM 没有任何保护。宿主 `local` 存储只有 50G，
      备份要放这里或者建个远端 PBS/NFS。

## 已完成 / 已明确不做

- [x] `conf.env` 移出版本库，加 `conf.env.example`
- [x] `reference/expected-9000.conf` 里的 `cipassword` / `sshkeys` 脱敏
- [x] `scan-secrets.sh`（含 `--self-test`，防止规则静默失效）
- [x] `CLOUD_IMG_URL` / `CLOUD_IMG_SHA256` 钉版本，保证可复现构建
- [x] 构建期内存按宿主余量自适应（`BUILD_MEM_MB` 留空即自动）
- [x] 清掉 `[special:cloudinit]` 残留
- [x] 修 `qm set --sshkeys` 收文件路径、cloud-init degraded 退出码、
      sshd drop-in 文件名优先级、QGA JSON 格式、host key 删除时机
- [x] 内存气球（`ballooning-target=100`），否则 VM 内存被自动回收
- [x] 独立公开仓库 + 作为 `aistudio` 的 submodule（跟随 `develop` 分支）
- [x] MIT 许可证

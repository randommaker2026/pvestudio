# 待办

## 1. `bootstrap.sh` 自动推导网络参数（建议做）

**问题**：`conf.env` 里这些值写死成本机网段，换一台 PVE 就全错：

```
GATEWAY=192.168.0.1
DNS=192.168.0.1
SEARCH_DOMAIN=lan
IP_POOL=192.168.0.100-192.168.0.199
BUILD_IP=192.168.0.249
```

`bootstrap.sh` 目前只做**检查**（网桥网段 vs `GATEWAY` 不同就 warn，第 91-95 行），
**不会自动推导**。换网段后失败方式是 VM 拿了个连不通的地址，比较隐蔽。

**方案**：在 `bootstrap.sh` 第 2 步（准备输入）里加推导并回写 `conf.env`：

- `GATEWAY` ← 网桥所在网段的 `.1`，或 `ip route` 的默认网关（取与 `$BRIDGE` 同段的）
- `DNS` ← 解析 `/etc/resolv.conf` 里第一个非环回 nameserver，兜底用 `GATEWAY`
- `SEARCH_DOMAIN` ← `resolv.conf` 的 `search` 域，没有就留空
- `IP_POOL` ← 取 `$BRIDGE` 网段，跳过前 10 和后 10 后的中间 100 个地址
- `BUILD_IP` ← `IP_POOL` 的第一个

只在 `conf.env` 里还是默认值时回写；用户手改过的值不覆盖。
`--check` 模式要一并显示"这些值是推导来的还是你手改的"。

**做完的效果**：换机器只需要改密码 + 装公钥两件事。

## 2. `./make-dist.sh` 同步派生产物（可选）

**问题**：`conf.env.example` 和 `reference/*` 现在是手工 `sed` / `cp` 出来的，
仓库里**没有任何脚本能重新生成**。改了 `conf.env` 之后 example 会和实际脱节。

**方案**：加一个脚本，一次做完：

1. `conf.env` → 脱敏 → `conf.env.example`（只把 `CI_PASSWORD` 换成占位符）
2. 当前 `/etc/pve/qemu-server/$TPL_VMID.conf` → 脱敏 → `reference/expected-9000.conf`
3. 当前 `/etc/pve/nodes/$PVE_NODE/config` → `reference/expected-node-config`
4. 跑 `./scan-secrets.sh --staged` 收尾

注意 `reference/expected-9000.conf` 里含**本机相关的字段**
（存储名、MAC、UUID、`meta.ctime`），换机器构建出来必然有差异 ——
`bootstrap.sh` 第 6 步的比对已经会自动忽略这些。

---

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
- [ ] 配 PVE 备份任务（`/etc/pve/jobs.cfg` 目前是空的，模板能重建但数据 VM 无保护）

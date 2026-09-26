# reference/ —— 期望值，不是待恢复的文件

这个目录里是**在 PVE 9.2.2 上跑完 `bootstrap.sh` 之后，产物的快照**，
用途只有一个：让新机器上构建出来的模板可以拿来比对，确认结果一致。

## ⚠️ 不要把它们 cp 回 /etc/pve

```
cp reference/expected-9000.conf /etc/pve/qemu-server/9000.conf   # 别这么干
```

这样只会得到一个指向不存在磁盘卷的坏 VM（`base-9000-disk-0/1` 没了）。
VM 配置必须由 `build-template.sh` 配合真实的 LVM 卷一起生成。

正确的"恢复"方式永远是重新构建：

```bash
./bootstrap.sh --force
```

## 文件说明

| 文件 | 对应 | 内容 |
|---|---|---|
| `expected-node-config` | `/etc/pve/nodes/pve/config` | 只有一行 `ballooning-target: 100` |
| `expected-9000.conf` | `/etc/pve/qemu-server/9000.conf` | 模板 VM 的完整配置 |

## 比对时故意忽略的字段

`bootstrap.sh` 第 6 步做 diff 时会跳过这些，因为每次构建必然不同：

```
meta          # creation-qemu / ctime
smbios1       # 随机 UUID
vmgenid       # 随机 UUID
net0          # 每次 clone 重新分配 MAC
description   # 里面带构建时间戳
scsi0/efidisk0/ide2   # 卷名前缀随 VMID 变（base-9000-* vs base-9001-*）
```

其余字段（cores / memory / balloon / bios / machine / scsihw / agent /
tablet / serial0 / vga / boot / cpu / ostype / citype / ciuser / ciupgrade /
nameserver / searchdomain / ipconfig0 / template / tags）都应当一致。

有差异不一定是 bug —— 参考文件只是某一次构建的快照，看一眼确认就行。

## 想更新参考文件

改完 `conf.env` 重建后，确认结果是你想要的，然后：

```bash
cp /etc/pve/qemu-server/9000.conf reference/expected-9000.conf
cp /etc/pve/nodes/pve/config  reference/expected-node-config
```

注意 `expected-9000.conf` 里含 `cipassword`（明文）和 `sshkeys`，
提交前确认一下是否合适。仓库的 `.gitignore` 没忽略这个文件——
如果不想让密码进版本库，考虑改成只保留脱敏版。

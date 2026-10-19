# Drill 8: etcd consensus lab

Run a 3-node etcd cluster, keep a writer running, then break things on purpose.
Takes about 30 minutes on quasarlab or any Docker host. Lab only: no TLS, no auth,
so don't expose these ports beyond your LAN.

The sample output below comes from one real run (etcd 3.5.17), where etcd3 started
as the leader. Your leader may differ, so substitute your own node names.

## 1. Start the cluster

```bash
cd 08-etcd-lab
docker compose up -d
docker compose exec etcd1 etcdctl --endpoints=etcd1:2379,etcd2:2379,etcd3:2379 endpoint status -w table
```

The table shows one node with `IS LEADER = true` and the same `RAFT TERM` on all three.
Whenever a node is down, run `etcdctl` through one that is still up
(`docker compose exec etcd2 ...`).

## 2. Start a writer in a second terminal

Pick one (all three print the same kind of line):

```bash
python3 python/etcd_writer.py
pwsh ./powershell/Watch-EtcdWrites.ps1
go run ./08-etcd-lab/go          # from the repo root
```

Running against quasarlab from another machine: pass
`--endpoints quasarlab:2379,quasarlab:22379,quasarlab:32379` (Python),
`-Endpoint ...` (PowerShell) or `-endpoints ...` (Go).

## 3. Crash the leader

```bash
docker kill <leader>     # etcd3 in the sample run
```

```
18:37:32.751  put lab/counter=17   OK    via localhost:2379     11 ms  term 2  rev 18
18:37:34.997  put lab/counter=18   FAIL  localhost:2379 timed out; localhost:22379 timed out; localhost:32379 connection refused
18:37:35.003  put lab/counter=19   OK    via localhost:2379      2 ms  term 3  rev 19
```

About 2 seconds of failures while the followers notice the missing heartbeats and
hold an election, then writes resume under a new term (2 to 3 here; a split vote
can add more than one).

## 4. Lose quorum

Leave the old leader down and kill one of the two remaining nodes:

```bash
docker kill etcd1        # leaves etcd2 as the only survivor in the sample run
```

```
18:37:40.257  put lab/counter=36   FAIL  localhost:2379 connection refused; localhost:22379 timed out; localhost:32379 connection refused
              serializable read from localhost:22379: lab/counter=35 (may be stale)
```

Every write fails. The survivor is alive and answering, but one node of three is not
a majority, so it cannot commit anything. Reads split by consistency level:

```bash
docker compose exec <survivor> etcdctl --command-timeout=3s put lab/counter 999
# Error: context deadline exceeded
docker compose exec <survivor> etcdctl get lab/counter --consistency=s
# lab/counter
# 35          <- serializable: local data, possibly stale
docker compose exec <survivor> etcdctl --command-timeout=3s get lab/counter
# Error: context deadline exceeded    <- linearizable (the default) needs quorum
```

## 5. Restore quorum

Start either stopped node:

```bash
docker start etcd3
```

```
18:37:45.773  put lab/counter=42   OK    via localhost:22379   492 ms  term 4  rev 36
```

Writes resume within about half a second, under yet another term.

## 6. Stop a leader gracefully

Bring everything back, find the current leader, and stop it cleanly this time:

```bash
docker compose start
docker compose exec etcd1 etcdctl --endpoints=etcd1:2379,etcd2:2379,etcd3:2379 endpoint status -w table
docker stop <leader>     # SIGTERM instead of SIGKILL; etcd2 in the sample run
```

```
18:38:33.354  put lab/counter=8    OK    via localhost:2379      3 ms  term 4  rev 92
18:38:33.603  put lab/counter=9    OK    via localhost:2379      3 ms  term 5  rev 93
```

No failed writes at all. On a clean shutdown the leader hands leadership to a
caught-up follower before exiting, so the term still goes up but nobody waits for an
election timeout. Planned maintenance is nearly free; crashes are not.

## 7. Check that everyone caught up

Stop the writer (Ctrl+C), run `docker compose start`, and check the status table again.
All three nodes show the same `RAFT INDEX`: the nodes that were down replayed the
leader's log when they came back. (With the writer still running, the index moves
between rows.)

## 8. Clean up

```bash
docker compose down
```

## Check yourself

- Why does a 3-node cluster survive one failure but not two? Why doesn't a 4-node cluster survive two?
- What does a new Raft term mean, and why did the graceful stop still bump it?
- Why can a serializable read return an old value, and when is that acceptable?
- The writer retries on the next node after a 1-second timeout. What would happen to the
  cluster if 6,000 clients did that with no backoff or jitter? (See drill 4.)

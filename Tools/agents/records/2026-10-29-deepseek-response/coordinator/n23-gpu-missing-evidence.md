# N23 定向补证原因
Sol已执行19项CPU列契约检查；sandbox中的MTLCreateSystemDefaultDevice为空，GPU构造器拒绝和setData清空未执行（exit77）。这是真实证据缺失，不是为了独立再确认。
只执行Sol已编译v2二进制的 --gpu-only，预期cpu_checks=0；不重编、不给19CPU再跑、不启动正式app、不跑像素全组。输入归属见Sol metal-contract-v2/inputs.json。完整输出由coordinator/capture.py留存，新增结果gpu-only-result.json；当前Metal源码后续若有变更需说明影响，不能自动继承。

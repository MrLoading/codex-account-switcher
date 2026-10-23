## 中文

- 修复 macOS 的 Tibo 重置预测显示“预测不可用”的问题。直接从预测接口读取 24 小时和 48 小时概率，移除历史接口依赖及推文发布时间与实际重置时间的交叉校验。
- 保留概率数值与数据时效检查，并在日志中记录具体获取失败原因。

## English

- Fix unavailable Tibo reset forecasts on macOS. Read the 24-hour and 48-hour probabilities directly from the forecast endpoint, removing the timeline dependency and the comparison between post publication and actual reset times.
- Keep probability and freshness checks, and log the specific cause when fetching fails.

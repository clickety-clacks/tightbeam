                            case "task_notification":
                                // The task settled — no further tool calls can originate
                                // from it, so its registry entry can be dropped.
                                await subagents.finishTask(message.task_id, message.status, sendUpdate, message.tool_use_id);
                                await asyncTasks.taskNotification({
                                    task_id: message.task_id,
                                    status: message.status,
                                    summary: message.summary,
                                    output_file: message.output_file,
                                });
                                if (message.tool_use_id)
                                    subagents.discardPending(message.tool_use_id);
                                session.liveBackgroundTasks.delete(message.task_id);
                                break;
                                if (message.patch.status === "completed" ||
                                    message.patch.status === "failed" ||
                                    message.patch.status === "killed") {
                                    await subagents.finishTask(message.task_id, message.patch.status, sendUpdate);
                                    session.liveBackgroundTasks.delete(message.task_id);
                                }

    async unstable_forkSession(params) {
        if (this.providerUpdate)
            await this.providerUpdate;
        return forkSession(params, {
            liveMessageIdToUuid: this.sessions[params.sessionId]?.messageIdToUuid,
            messageIdForGrouping,
        });
    }

// Discovered from the test project's OMP settings, never passed as a CLI hook.
export default function (pi: any) {
  pi.registerTool({
    name: 'dieter_rpc_question', label: 'Native RPC question', loadMode: 'essential',
    description: 'Ask the human to choose Red or Blue using the native extension UI. Use this tool when the user asks for the RPC question test.',
    parameters: pi.zod.object({}),
    async execute(_id: string, _params: unknown, _signal: AbortSignal, _update: unknown, ctx: any) {
      const answer = await ctx.ui.select('Native OMP RPC choice', ['Red', 'Blue']);
      return { content: [{ type: 'text', text: `OMP_RPC_CHOICE_${answer || 'CANCELED'}` }] };
    },
  });
  pi.registerTool({
    name: 'dieter_rpc_wait', label: 'Native RPC wait', loadMode: 'essential',
    description: 'Wait in an interruptible tool for the native RPC restart test.',
    parameters: pi.zod.object({}),
    async execute(_id: string, _params: unknown, signal: AbortSignal) {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(resolve, 3000);
        signal.addEventListener('abort', () => { clearTimeout(timer); reject(new Error('RPC fixture interrupted')); }, { once: true });
      });
      return { content: [{ type: 'text', text: 'OMP_RPC_WAIT_COMPLETED' }] };
    },
  });
}

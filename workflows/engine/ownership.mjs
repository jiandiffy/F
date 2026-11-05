import { GoalState } from '../../packages/agent-bus/agent/state.mjs';

export async function workflowAccess() {
  if(!process.env.F_WORKFLOW_STATE_FILE || !process.env.F_WORKFLOW_ROLE)return null;
  const goal=await new GoalState({file:process.env.F_WORKFLOW_STATE_FILE}).current();
  const all=items=>items.flatMap(c=>[c,...all(c.children??[])]);
  const candidate=all(goal?.stages.at(-1)?.candidates??[]).find(c=>c.id===process.env.F_WORKFLOW_CANDIDATE);
  const role=process.env.F_WORKFLOW_ROLE,id=process.env.F_AGENT_ID;
  if(!candidate || !candidate.attempts?.some(a=>a.childId===id&&a.role===role))throw new Error('This agent is not assigned to the current workflow branch');
  return{candidate,canWrite:(role==='experiment'&&candidate.phase==='working')||(role==='simplifier'&&candidate.phase==='simplifying')};
}

-- Does not undo settlements that have already been generated.
-- Run deliberately if you need to halt automatic month closing.
select cron.unschedule(jobid) from cron.job where jobname='chai-khapa-month-close';

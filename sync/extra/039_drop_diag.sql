-- removes the temporary Carlo view speed check
DROP FUNCTION IF EXISTS public._diag_cv_plan(int);
DROP FUNCTION IF EXISTS public._diag_cv_plan();

-- Unvoid my concepts and void OCL's replacements
 
-- This finds concepts where your names were voided with reason "Removed from OCL"

-- and OCL inserted replacement names at the same time.
 
-- Step 1: Create a temp table of concepts that got replaced

CREATE TEMPORARY TABLE replaced_concepts AS

SELECT DISTINCT concept_id

FROM concept_name

WHERE void_reason = 'Removed from OCL'

  AND voided = 1;
 
-- Step 2: Unvoid your original names

UPDATE concept_name

SET

    voided = 0,

    voided_by = NULL,

    date_voided = NULL,

    void_reason = NULL

WHERE concept_id IN (

    SELECT concept_id

    FROM replaced_concepts

)

AND void_reason = 'Removed from OCL';
 
-- Step 3: Void OCL's replacement names

UPDATE concept_name

SET

    voided = 1,

    voided_by = 1,

    date_voided = NOW(),

    void_reason = 'Replaced by original'

WHERE concept_id IN (

    SELECT concept_id

    FROM replaced_concepts

)

AND voided = 0

AND creator = 2

AND date_created >= '2026-06-16';
 
-- Prevent re-importing on next startup

cd /openmrs/data/configuration/ocl/
 
mv CIEL_CIEL_v2024-07-26.2024-07-30_020742.zip \

   CIEL_CIEL_v2024-07-26.2024-07-30_020742.zip.DONE
 
-- Since concepts survived, clean up the temporary table

DROP TEMPORARY TABLE replaced_concepts;
 

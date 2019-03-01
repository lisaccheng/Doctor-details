--finding out the doctor details responsible for the patient  

CREATE VOLATILE TABLE vt_doctor AS 
( 
SELECT 
a.* 

FROM 
            ( 
            SELECT 
                pop.Patient_ID 
                , t01.Doctor_ID 
                , 'Doctor links' AS DATASOURCE 
                , t01.Link_Date AS Start_Date 
                , NULL(DATE) AS Doctor_DOB                 

            FROM            DB.population AS pop --This population has details of the patient only 

            LEFT JOIN       DB.Doctor_links AS t01 
            ON              pop.Patient_ID=t01.Patient_ID 

            WHERE           t01.Link_Type_Code IN(30,35) --Doctor to Patient Link 

            UNION 

            SELECT 
            t01.Patient_ID  
            , Mtchd_ID AS Doctor_ID 
            , 'Health Centre' AS DATASOURCE 
            , t00.Role_Start_Date AS Start_Date 
            , To_Date(DOB, 'DD/MM/YYYY') AS Doctor_DOB 

            FROM DB.Doctor_Reference t00 

            INNER JOIN ( 
                SELECT   
                    A1.Doc_Num, 
                    A2.Doctor_Id, 
                    A1.Doc_Name 
                FROM    DB.Doc_Organisation A1 

                INNER JOIN ( 
                        SELECT 
                            Patient_ID, 
                            Doc_Num, 
                            Reg_Date, 
                        FROM    DB.Doc_database 
                    ) A2 
                ON A1.Doc_Num = A2.Doc_Num 
                WHERE   A2.Patient_ID IN (SELECT Patient_ID FROM DB.population) 
                QUALIFY Row_Number() Over(PARTITION BY A1.Doc_Num ORDER BY  A1.Start_date DESC) = 1  
            ) t01 
            ON t00.Doc_Num = t01.Doc_Num            

            LEFT JOIN ( 
            SELECT 
                Doc_Num, 
                Trim(Frst_Nm) || ' ' || Trim(Othr_Gvn_Nm) || ' ' || Trim(Srnm) AS Full_Name, 
                Trim((Brth_Day)(Format'99')) || '/' || Trim((Brth_Mnth)(Format'99')) || '/' || Trim(Brth_Yr) AS DOB, 
                Mtchd_ID 
            FROM DB.Match_Data 
            ) t02 
            ON t00.Member_Num = t02.Doc_Num 

            WHERE t00.Role_End_Date IS NULL --null means current 
            AND   t00.Role_Type IN ('PD') --Primary Doctor 
            AND   t02.Mtchd_ID IS NOT NULL  
            AND   t02.Mtchd_ID <> 0 
            QUALIFY Row_Number() Over (PARTITION BY Patient_ID, Doctor_ID ORDER BY t00.Role_Start_Date  DESC)=1 
            ) a 

QUALIFY Row_Number() Over(PARTITION BY Patient_ID, Doctor_ID, DATASOURCE ORDER BY Start_Date DESC)=1          
) 
WITH DATA 
PRIMARY INDEX(Patient_ID) 
ON COMMIT PRESERVE ROWS 
; 


CREATE VOLATILE TABLE vt_doctor_pop AS 
( 
SELECT 
    pop.Patient_ID 
    , Doctor_ID 
    , t00.Client_Key AS Doctor_Key 
    , DATASOURCE 
    , CASE DATASOURCE 
                WHEN 'Doctor Link' THEN 1 
                WHEN 'Health Centre' THEN 2 
    END AS Priority      
    , Start_Date 
    , Doctor_DOB  

FROM            vt_doctor AS pop 

LEFT JOIN       DB.Clnt_Key  AS t00 
ON              pop.Doctor_ID=Cast(t00.Client_Val_Key AS DECIMAL(12,0)) 
AND             t00.Clnt_Key_Type =15  --Doctor ID 
AND             t00.Clnt_Key_Status = 15   --Client status active 
AND             t00.Clnt_Key_End_Dt > Current_Date  --additional check for active client status 

QUALIFY Row_Number() Over(PARTITION BY pop.Patient_ID, Doctor_ID ORDER BY  Priority ASC)=1 
) 
WITH DATA 
PRIMARY INDEX(Patient_ID, Doctor_ID) 
ON COMMIT PRESERVE ROWS 
; 

 
--DOB details for Doctor 
CREATE VOLATILE TABLE vt_dob AS 
( 
SELECT 
    pop.Patient_ID 
    , pop.Doctor_ID 
    , t01.Client_Key 
    , t01.idv_brth_day_num 
    , t01.idv_brth_mth_num 
    , t01.idv_brth_yr 
  , CASE 
   WHEN t01.idv_brth_yr BETWEEN 1 AND 9999 
   AND t01.idv_brth_mth_num    BETWEEN 1 AND 12 
   AND t01.idv_brth_day_num BETWEEN 1 AND 
        CASE 
            WHEN t01.idv_brth_mth_num IN (1,3,5,7,8,10,12) THEN 31 
            WHEN t01.idv_brth_mth_num IN (4,6,9,11) THEN 30 
            ELSE 28 + CASE  
                        WHEN (t01.idv_brth_yr  MOD 4 = 0 AND t01.idv_brth_yr  MOD 100 <> 0) 
                            OR t01.idv_brth_yr  MOD 400 = 0 
                        THEN 1 
                        ELSE 0 
                        END 
                    END 
        THEN ((t01.idv_brth_yr-1900)*10000 + (t01.idv_brth_mth_num * 100) + t01.idv_brth_day_num (DATE) ) 
    ELSE NULL 
    END AS birth_date  

FROM        vt_doctor_pop AS pop 

INNER JOIN  DB.client AS t01 
ON          pop.Doctor_Key = t01.Client_Key 

QUALIFY Row_Number() Over(PARTITION BY Patient_ID, Doctor_ID ORDER BY birth_date DESC, Priority ASC)=1 
) 
WITH DATA 
PRIMARY INDEX(Patient_ID, Doctor_ID) 
ON COMMIT PRESERVE ROWS; 

 
/*Grabbing names of doctors*/ 
CREATE VOLATILE TABLE vt_name AS  
(  
SELECT 
    pop.Patient_ID 
    , pop.Doctor_ID 
    , pop.Doctor_Key 
    , DATASOURCE 
    , Start_Date 
    , t01.Given_name 
    , t01.Family_Name 

FROM        vt_doctor_pop AS pop 

LEFT JOIN   DB.Client_Name AS t01 
ON          pop.Doctor_Key=t01.Client_Key 
AND         clnt_nm_sts = 15 /* Only currently active names */ 
AND         clnt_nm_current_ind = 'Y' 

INNER JOIN  DB.Name_Type AS t02 
ON          t01.nm_cd=t02.nm_cd 
AND         t02.nm_cd IN (15,20) /* This references the type of name */ 

QUALIFY Row_Number() Over(PARTITION BY pop.Patient_ID, Doctor_ID ORDER BY Clnt_Nm_Created_Date DESC, Priority ASC)=1 
)  
WITH DATA 
PRIMARY INDEX(Patient_ID, Doctor_ID) 
ON COMMIT PRESERVE ROWS;   


--Final flattened table, combining all details together 
CREATE VOLATILE TABLE vt_combined AS 
( 
SELECT 
    pop.Patient_ID 
    , pop.Doctor_ID 
    , pop.DATASOURCE 
    , pop.Start_Date 
    , t01.Given_name 
    , t01.Family_name 
    , t02.birth_date    
    , pop.Doctor_DOB  
    , CASE WHEN birth_date <> Doctor_DOB THEN 'Y' ELSE 'N' END AS DOB_Check_required 
    , t03.POS_Address 
    , t03.RES_Address 
    , t03.BUS_Address 

FROM           vt_doctor_pop AS pop 

INNER JOIN     vt_name AS t01 
ON             pop.Patient_ID=t01.Patient_ID 
AND            pop.Doctor_ID=t01.Doctor_ID 

INNER JOIN     vt_dob AS t02 
ON             pop.Patient_ID=t02.Patient_ID 
AND            pop.Doctor_ID =t02.Doctor_ID 

QUALIFY Row_Number() Over(PARTITION BY Patient_ID, pop.Doctor_ID, pop.DATASOURCE ORDER BY pop.Priority ASC)=1 
) 
WITH DATA 
PRIMARY INDEX (Patient_ID, Doctor_ID) 
ON COMMIT PRESERVE ROWS 
; 


SELECT * FROM vt_combined 
ORDER BY 1 
; 

 

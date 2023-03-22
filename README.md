# 10X Autopipeline
Process 10X library from fastq files to QC report with a single command. The different modules can also be run individually if needed. 
![schematics](/doc/Drawing.png "schematics")

## Run all modules
```
aws batch submit-job \
--job-name 'jobname' \
--job-queue 'default-gwf-nextflow-test' \
--job-definition 'nextflow-head-test' \
--container-overrides 'command="https://gitlab.com/proteona/proteona_main/bioinformatics/research/playground/10x_endtoend_pipeline.git",
"--resultfolder s3://s3pathtoresultfolder",
"--runfolder s3://s3pathtorunfolder",
"--QCDB_pid projectid"'
```
The above command runs the full pipeline. The following parameters should be changed accordingly:
| Parameter      | Explanation                                                                                             |
|----------------|---------------------------------------------------------------------------------------------------------|
| --job-name     | Job name to identify your job in aws batch                                                              |
| --resultfolder | Path in S3 to store all outputs. Outputs from different modules will be put into different folders. **Use only genworkflowres bucket** |
| --runfolder    | Path in S3 containing fastq files that have been properly named according to cellranger's requirements. |
| --QCDB_pid     | Project ID to store Cellranger's QC metrics under in snowflake                                          |

If you want to run full pipeline but not upload QC metrics to QCDB, add `--QCDB_skip 1`. There are other parameters which can be changed. Refer to [full set of parameters](#full-set-of-parameters)

## Run cellranger only 
```
aws batch submit-job \
--job-name 'jobsname' \
--job-queue 'default-gwf-nextflow-test' \
--job-definition 'nextflow-head-test' \
--container-overrides \
'command="https://gitlab.com/proteona/proteona_main/bioinformatics/research/playground/10x_endtoend_pipeline.git",
"--modules_to_run cellranger",
"--resultfolder s3://s3pathtoresultfolder",
"--runfolder s3://s3pathtorunfolder",
"--cellranger_listparameters s3://s3pathtolistparameters.csv",
"--cellranger_cpus 48",
"--cellranger_memory 384.GB"
```
Some samples may fail cellranger processing due to out of memory or chemistry autodetection issues. Check the logs for details. If the log shows "signal:killed" with no other errors and the jobs details shows "OutOfMemoryError: Container killed due to memory usage", then the issue is insufficient memory. The pipeline will terminate after the cellranger module if that happens, but outputs from the successful cellranger processes will still be stored in S3. To re-run cellranger module on failed samples, add the following arguments: 
- `--modules_to_run cellranger` to run the cellranger module only
- `--cellranger_listparameters s3://pathtolistparameters.csv` to point to listparameters.csv that contains only the samples that needed re-running
- `--cellranger_cpus 48` and `--cellranger_memory 384.GB` to use an instance with higher memory capacity. The default is 32 CPUs and 256 GB memory. Here we increased to 48 CPUs and 384 GB. 

## Resume pipeline after cellranger
```
aws batch submit-job \
--job-name 'jobsname' \
--job-queue 'default-gwf-nextflow-test' \
--job-definition 'nextflow-head-test' \
--container-overrides \
'command="https://gitlab.com/proteona/proteona_main/bioinformatics/research/playground/10x_endtoend_pipeline.git",
"--modules_to_run resumeseurat",
"--resultfolder s3://s3pathtoresultfolder",
"--QCDB_pid projectid"'
```
Run the pipeline from after cellranger onwards. This is useful if some cellranger processes failed, you have rerun them successfully, and want to continue on with the pipeline. This assumes the cellranger outputs are in the 'cellranger_multi' folder in the result folder specified by `--resultfolder`. If the cellranger outputs are not stored in a folder called 'cellranger_multi', then specify the full path with the `--cellranger_output` argument. 

## Notifications
Subscribe to the '10x_endtoend' topic in SNS to receive notification when major steps in pipeline complete or when error is encountered. Unsubscribe if you are not running the pipeline to not receive notification from other people's pipeline run.  

## Automatic retries
The merge seurat objects step may fail due to out of memory if there are many samples. The pipeline is configured to re-run the module automatically if the exit code indicates memory issue, with the memory provision increased to (original memory * task attempt). The maximum number of automatic retries is 2. The default original memory is 32 GB. This can be changed with the `--mergeseurat_memory` argument if you already know from experience that you will need more memory than that for the samples you are processing, and want to succeed without automatic retries. 
This automatic retry mechanism is not implemented for the cellranger process as cellranger (v6.0.2) doesn't emit an exit code corresponding to memory issues when it runs out of memory. 

## Full set of parameters
| Parameters                        | Default                                                                               | Explanation                                                                                        |
|-----------------------------------|---------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| modules_to_run                    | all                                                                                   | Which modules to run. Can also be 'ETL', 'cellranger', 'seurat',   'resumeseurat', 'QC' or 'QCDB'. |
| resultfolder                      | NA                                                                                    | S3 path to store pipeline ouputs                                                                   |
| runfolder                         | NA                                                                                    | S3 path containing fastq files                                                                     |
| ETL_dockeruri                     | dkr.ecr.ap-southeast-1.amazonaws.com/10x_etl:latest                      | Docker image for performing ETL                                                                    |
| cellranger_RNAreference           | s3://proteona-cellranger/references/GRCh38-3.0.0/                                     | S3 path to RNA reference                                                                           |
| cellranger_VDJreference           | s3://proteona-cellranger/references/refdata-cellranger-vdj-GRCh38-alts-ensembl-5.0.0/ | S3 path to VDJ reference                                                                           |
| cellranger_ADTreference           | s3://proteona-cellranger/feature_bc/Totalseq.Ab.Barcodes_Oct2022.csv                  | S3 path to ADT barcode csv file                                                                    |
| cellranger_introns                | True                                                                                  | Cellranger parameters to include intron or not                                                     |
| cellranger_cpus                   | 16                                                                                    | Instance CPU size for running cellranger                                                           |
| cellranger_memory                 | 128.GB                                                                                | Instance memory size for running cellranger                                                        |
| cellranger_dockeruri              |  dkr.ecr.ap-southeast-1.amazonaws.com/cellranger-nf:latest             | Docker image for cellranger                                                                        |
| cellranger_librarycsv             | resultfolder + '/library_csv'                                                         | S3 path to store library csv files                                                                 |
| cellranger_listparameters         | resultfolder + '/library_csv/listparameters.csv'                                      | S3 path to store listparameters.csv                                                                |
| cellranger_output                 | resultfolder + '/cellranger_multi'                                                    | S3 path to store cellranger output                                                                 |
| makeseurat_cpus                   | 2                                                                                     | Instance CPU size for generating seuratobjects                                                     |
| makeseurat_memory                 | 16.GB                                                                                 | Instance memory size for generating seuratobjects                                                  |
| mergedseuratobj                   | resultfolder + '/seuratobj/seuratobj_merged.rds'                                      | S3 path to store merged seuratobject rds file                                                      |
| seurat_dockeruri                  |  dkr.ecr.ap-southeast-1.amazonaws.com/10x_seurat:latest             | Docker image for generating seuratobjects                                                          |
| mapcell_bmjci                     | False                                                                                 | Annotate with Mapcell bmjci?                                                                       |
| mapcell_bmcite                    | False                                                                                 | Annotate with Mapcell bmcite?                                                                      |
| mapcell_bmcite_RNA                | False                                                                                 | Annotate with Mapcell bmcite RNA only?                                                             |
| mapcell_bmcite_RNA_overlappingADT | False                                                                                 | Annotate with Mapcell bmcite RNA + overlapping ADT?                                                |
| mapcell_pbmc                      | False                                                                                 | Annotate with Mapcell pbmc?                                                                        |
| mapcell_pbmc_RNA                  | True                                                                                  | Annotate with Mapcell pbmc RNA only?                                                               |
| mapcell_pbmc_RNA_overlappingADT   | False                                                                                 | Annotate with Mapcell pbmc RNA + overlapping ADT?                                                  |
| WNN_PBMC                          | False                                                                                 | Annotate with WNN pbmc?                                                                            |
| WNN_BM                            | False                                                                                 | Annotate with WNN bmcite?                                                                          |
| mergeseurat_cpus                  | 4                                                                                     | Instance CPU size for merging seuratobjects                                                        |
| mergeseurat_memory                | 32.GB                                                                                 | Instance memory size for merging seuratobjects                                                     |
| QC_cpus                           | 4                                                                                     | Instance CPU size for generating QC report                                                         |
| QC_memory                         | 32.GB                                                                                 | Instance memory size for generating QC report                                                      |
| QC_dockeruri                      | dkr.ecr.ap-southeast-1.amazonaws.com/10x_qc:latest                       | Docker image for generating QC report                                                              |
| QC_output                         | resultfolder + '/QC'                                                                  | S3 path to store QC output                                                                         |
| QCDB_pid                          | NA                                                                                    | Project ID in snowflake to store cellranger metrics                                                |
| QCDB_testmode                     | 0                                                                                     | Set to 1 to store cellranger metrics in a test database in snowflake                               |
| QCDB_mergedmetrics                | NA                                                                                    | S3 path to merged_metrics.csv. Not needed if running end-to-end mode.                              |
| QCDB_skip                         | 0                                                                                     | Set to 1 to skip uploading metrics to QCDB                                                         |
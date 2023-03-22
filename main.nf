nextflow.enable.dsl=2

//Dependent parameters that can be specified
params.cellranger_librarycsv=params.resultfolder - ~/\/$/ + '/library_csv'
params.cellranger_listparameters=params.resultfolder - ~/\/$/ + '/library_csv/listparameters.csv'
params.cellranger_output=params.resultfolder - ~/\/$/ + '/cellranger_multi'
params.mergedseuratobj=params.resultfolder - ~/\/$/ + '/seuratobj/seuratobj_merged.rds'
params.QC_output=params.resultfolder - ~/\/$/ + '/QC'


//Internal variables
public_seuratinputcsv="seuratinput.csv"
public_mergedmetricscsv="metrics_merged.csv"
def jobID_inp=["/bin/bash", "-c", 'echo ${AWS_BATCH_JOB_ID:-localrun}'].execute().text.trim() //Obtain job ID of headjob

process create_librarycsv {

input:
val src_S3
val dest_s3

output:
val true

script:
    """
    ETL.create_sample_library.py \
    --src_s3 $src_S3 \
    --dest_s3 $dest_s3 
    """
}

process create_listparametercsv {

input:
val signalcomplete

output:
val true, emit: signal
path "listparameters.csv", emit: listparameters

script:
    """
    ETL.create_inpforcellranger.py  \
    --s3path ${params.cellranger_librarycsv} \
    --transcriptome_s3path ${params.cellranger_RNAreference} \
    --vdj_reference_s3path ${params.cellranger_VDJreference} \
    --feature_s3path ${params.cellranger_ADTreference} \
    --runfolder_s3path ${params.runfolder} \
    --resfolder_s3path ${params.cellranger_output} \
    --introns ${params.cellranger_introns} \
    --outfile ${params.cellranger_listparameters}
    aws sns publish --topic-arn arn:aws:sns:ap-southeast-1:341049626633:10x_endtoend --subject "${jobID_inp}:Listparameters.csv generated" --message "Listparameters generated for ${params.runfolder} and uploaded to ${params.cellranger_librarycsv}" --region "ap-southeast-1"
    """
}


process cellranger_multi {
        
        input:
        val upstream_signal
    tuple val(LibraryS3Path), val(TranscriptomeS3Path), val(VDJReferenceS3Path), val(FeatureS3Path), val(RunFolderS3Path),  val(RunID), val(ResFolderS3Path), val(ForceChemistry), val(ForceCells), val(TSOS3Path), val(IsIncludeIntrons), val(IsTCR), val(IsBCR)
    
        output:
        val RunID, emit: sampleid

        script:        
		"""
		cellranger.run_cellranger_multi.py --library_s3_path $LibraryS3Path \
				--transcriptome_s3_path $TranscriptomeS3Path \
				--featureref_s3_path $FeatureS3Path \
				--vdjreference_s3_path $VDJReferenceS3Path \
				--runfolder_s3_path $RunFolderS3Path \
				--resfolder_s3_path $ResFolderS3Path \
				--chemistry $ForceChemistry \
				--force-cells $ForceCells \
				--work_dir ${params.cellranger_workdir} \
				--runId $RunID \
				--include-introns $IsIncludeIntrons \
				--tso_file $TSOS3Path \
				--testcpu ${params.cellranger_testcpu} \
                --testmemory ${params.cellranger_testmemory} \
                --local_RNA_reference ${params.cellranger_local_RNA_reference} \
                --local_VDJ_reference ${params.cellranger_local_VDJ_reference}
		"""
        stub:
        """
        echo "Stub proces for testing purpose"
        """
        
}

process check_cellranger {

    input: 
    val sampleid_list
    val listparameters // github.com/nextflow-io/nextflow/issues/378 
    
    output:
    val true
    
    script:
    samplesize=sampleid_list.size()
    listparameters_rows=listparameters.countLines()-1
    log.info("Checkcellranger processes. Output size is ${samplesize}. Input size is ${listparameters_rows}")
     if (samplesize == listparameters_rows)
     """
     aws sns publish --topic-arn arn:aws:sns:ap-southeast-1:341049626633:10x_endtoend --subject "${jobID_inp}:Cellranger passed" --message "All cellranger processes completed successfully. Results uploaded to ${params.resultfolder}/cellranger_multi" --region "ap-southeast-1"
     """
     else 
     """     
     echo "1 or more cellranger processes failed. Results of succeeded process uploaded to ${params.resultfolder}/cellranger_multi. Terminating pipeline. Please check aws jobs for details." 1>&2
     exit 1
     """
}

process parse_S3 {

input:
val signalcomplete
val s3_path

output:
path "${public_seuratinputcsv}"

script:
"""
seurat.parse_S3.py --s3dir "${s3_path}" --outfile "${public_seuratinputcsv}"
"""

}

process make_seuratobjs {

    input:
    tuple val(sampleid), val(h5_path), val(bcr_path), val(tcr_path)

    output:
    path "${sampleid}_seuratobj.rds", emit: seuratobj
    
    script:
    """
    seurat.createseuratobjs.r \
    ${sampleid} \
    ${h5_path} \
    ${bcr_path} \
    ${tcr_path} \
    ${params.mapcell_bmjci} \
    ${params.mapcell_bmcite} \
    ${params.mapcell_bmcite_RNA} \
    ${params.mapcell_bmcite_RNA_overlappingADT} \
    ${params.mapcell_pbmc} \
    ${params.mapcell_pbmc_RNA} \
    ${params.mapcell_pbmc_RNA_overlappingADT} \
    ${params.WNN_PBMC} \
    ${params.WNN_BM}     
    """
}

process merge_seuratobjs {    
   
    input:
    path "*.rds"
    val mergedseurat_output_s3
    
    output:
    val true
    
    script:
    """
    seurat.mergeseuratobjs.r "${mergedseurat_output_s3}"
     aws sns publish --topic-arn arn:aws:sns:ap-southeast-1:341049626633:10x_endtoend --subject "${jobID_inp}:Seurat object made" --message "Seurat object uploaded to ${mergedseurat_output_s3}. " --region "ap-southeast-1"
    """

}

process merge_metrics {
    

    input:
    val upstream_signal
    val cellranger_multi_path

    output:
    path "${public_mergedmetricscsv}"

    script:    
    """
    QC.merge_metrics.py --s3dir ${cellranger_multi_path} --outfile ${public_mergedmetricscsv}    
    """
}

process perform_QC {

    input:
    path "${public_mergedmetricscsv}"
    path mergedseurat_input_s3
    val QC_output
    path rmd
    
    output:
    val true
    path "*.pdf"
    path "${public_mergedmetricscsv}"
    path "*.html"
    
    script:
    inputs3=mergedseurat_input_s3.name
    """
    QC.plot_qc.r "${public_mergedmetricscsv}" \
    "${inputs3}" \
    "${QC_output}" \
    "${rmd}"
     aws sns publish --topic-arn arn:aws:sns:ap-southeast-1:341049626633:10x_endtoend --subject "${jobID_inp}:QC completed" --message "QC results uploaded to ${QC_output}. " --region "ap-southeast-1"
    """

}

process QCDB {

    input:
    path "${public_mergedmetricscsv}"
    val pid
    val test
    
    script:
    """
    export SNOWFLAKE_USERNAME=\$(aws ssm get-parameter --name '/gwfcore/10xautopipeline/snowflake_username' --with-decryption --query 'Parameter.Value' --output text --region "ap-southeast-1")
    export SNOWFLAKE_PASSWORD=\$(aws ssm get-parameter --name '/gwfcore/10xautopipeline/snowflake_password' --with-decryption --query 'Parameter.Value' --output text --region "ap-southeast-1")
    ingest_Raw_Metrics.py --f "${public_mergedmetricscsv}" --pid "${pid}" --t "${test}"
    aws sns publish --topic-arn arn:aws:sns:ap-southeast-1:341049626633:10x_endtoend --subject "${jobID_inp}:QCDB completed" --message "Cellranger metrics uploaded to QCDB." --region "ap-southeast-1"
    """
}

workflow {    
    switch("${params.modules_to_run}"){
    case "all":
        run_ETL=true
        run_CR=true
        run_Seurat=true
        run_QC=true
        run_QCDB=true
        break    
    case "ETL":
        run_ETL=true
        run_CR=false
        run_Seurat=false
        run_QC=false
        run_QCDB=false
        break        
    case "cellranger":
        run_ETL=false
        run_CR=true
        run_Seurat=false
        run_QC=false
        run_QCDB=false
        break        
    case "seurat":
        run_ETL=false
        run_CR=false
        run_Seurat=true
        run_QC=false
        run_QCDB=false
        break        
    case "resumeseurat":
        run_ETL=false
        run_CR=false
        run_Seurat=true
        run_QC=true
        run_QCDB=true
        break    
    case "QC":
        run_ETL=false
        run_CR=false
        run_Seurat=false
        run_QC=true
        run_QCDB=false
        break
    case "QCDB":
        run_ETL=false
        run_CR=false
        run_Seurat=false
        run_QC=false
        run_QCDB=true
        break
    default:
        log.error('Unrecognized module to run. Please provide either all, ETL, cellranger, seurat, resumeseurat, QC or QCDB as argument to modules_to_run')
        exit 1    
        break   
    }
    
    if (run_ETL) {
        create_librarycsv(params.runfolder, params.cellranger_librarycsv)
        create_listparametercsv(create_librarycsv.out)
    }

    if (run_CR) {
        if (run_ETL) {
            cellranger_upstream_signal=create_listparametercsv.out.signal
            listparameter_ch=create_listparametercsv.out.listparameters
            } else {
                cellranger_upstream_signal=true
                listparameter_ch=Channel.fromPath(params.cellranger_listparameters)
            }
            
        cellranger_multi_input=listparameter_ch
                            .splitCsv(header:true)
                            .map { row -> tuple(row.LibraryS3Path,
                            row.TranscriptomeS3Path,
                            row.VDJReferenceS3Path,
                            row.FeatureS3Path,
                            row.RunFolderS3Path,
                            row.RunID,
                            row.ResFolderS3Path,
                            row.ForceChemistry,
                            row.ForceCells,
                            row.TSOS3Path,
                            row.IsIncludeIntrons,
                            row.IsTCR,
                            row.IsBCR)            
                            }

        cellranger_multi(cellranger_upstream_signal, cellranger_multi_input)
        cellranger_sampleidlist=cellranger_multi.out.sampleid.collect()
        check_cellranger(cellranger_sampleidlist, listparameter_ch) //Have to use file channel instead of s3 path or nextflow will skip to downloading s3 path first
        
        }

    if (run_Seurat) { 

        if (run_CR) {            
            seurat_upstream_signal=check_cellranger.out
        } else {
            seurat_upstream_signal=true
        }
 

        parse_S3(seurat_upstream_signal, params.cellranger_output)
        seurat_rows=parse_S3.out
            .splitCsv(header:true)
            .map { row -> tuple( 
            row.sampleid,
            row.h5_s3path,
            row.bcr_s3path,
            row.tcr_s3path
            )
            }

        make_seuratobjs(seurat_rows)

        seuratobj_collected=make_seuratobjs.out.seuratobj.collect()
        merge_seuratobjs(seuratobj_collected, params.mergedseuratobj)

        }


    if (run_QC) {

        if (run_Seurat) {
            QC_upstream_signal=merge_seuratobjs.out
         } else {
            QC_upstream_signal=true
            }
        merge_metrics(QC_upstream_signal, params.cellranger_output)
        perform_QC(merge_metrics.out, 
        Channel.fromPath(params.mergedseuratobj),
        params.QC_output, 
        Channel.fromPath("${projectDir}/QC/interactive_thresholds.Rmd"))
        }
        
    if (run_QCDB && params.QCDB_skip!=1) {
    
        if (params.QCDB_pid=='') {
            log.error("Please provide project ID for QCDB.")
            exit 1
        }
        
        else {    
            if (run_QC) {
                QCDB(merge_metrics.out, params.QCDB_pid, params.QCDB_testmode)
            }
            else {
                QCDB(Channel.fromPath(params.QCDB_mergedmetrics), params.QCDB_pid, params.QCDB_testmode)
            }
        }
    
    }
}


workflow.onError {
    def sendmsg=["aws",
    "sns",
    "publish",
    "--topic-arn",
    "arn:aws:sns:ap-southeast-1:341049626633:10x_endtoend",
    "--subject",
    "${jobID_inp}: Error encountered, pipeline terminated.",
    "--message",
    "${workflow.errorMessage}",
    "--region",
    "ap-southeast-1"].execute()    
    sendmsg.waitFor()

}
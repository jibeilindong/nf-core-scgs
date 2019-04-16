#!/usr/bin/env nextflow
/*
========================================================================================
                         gongyh/nf-core-scgs
========================================================================================
 gongyh/nf-core-scgs Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/gongyh/nf-core-scgs
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run gongyh/nf-core-scgs --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    Options:
      --genome                      Name of iGenomes reference
      --singleEnd                   Specifies that the input is single end reads

    References:                     If not specified in the configuration file or you wish to overwrite any of the references.
      --fasta                       Path to Fasta reference
      --gff                         Path to GFF reference

    Species related:
      --genus                       Genus information for use in CheckM
      --database                    Genome database (TBD)

    Trimming options:
      --notrim                      Specifying --notrim will skip the adapter trimming step.
      --saveTrimmed                 Save the trimmed Fastq files in the the Results directory.
      --clip_r1 [int]               Instructs Trim Galore to remove bp from the 5' end of read 1 (or single-end reads)
      --clip_r2 [int]               Instructs Trim Galore to remove bp from the 5' end of read 2 (paired-end reads only)
      --three_prime_clip_r1 [int]   Instructs Trim Galore to remove bp from the 3' end of read 1 AFTER adapter/quality trimming has been performed
      --three_prime_clip_r2 [int]   Instructs Trim Galore to re move bp from the 3' end of read 2 AFTER adapter/quality trimming has been performed

    Mapping options:
      --allow_multi_align           Secondary alignments and unmapped reads are also reported in addition to primary alignments
      --saveAlignedIntermediates    Save the intermediate BAM files from the Alignment step  - not done by default

    Quast options:
      --euk                         Euk genome

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// default values
params.genome = false
params.notrim = false
params.saveTrimmed = false
params.allow_multi_align = false
params.saveAlignedIntermediates = false
params.euk = false
params.genus = null
params.database = null
params.readPaths = null

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// TODO nf-core: Add any reference files that are needed
// Configurable reference genomes
fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
if ( params.fasta ){
    fasta = file(params.fasta)
    if( !fasta.exists() ) exit 1, "Fasta file not found: ${params.fasta}"
}
//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the above in a process, define the following:
//   input:
//   file fasta from fasta
//

gff = params.genome ? params.genomes[ params.genome ].gtf ?: false : false
if ( params.gff ){
    gff = file(params.gff)
    if( !gff.exists() ) exit 1, "GFF file not found: ${params.gff}"
}

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  if (!workflow.workDir.startsWith('s3') || !params.outdir.startsWith('s3')) exit 1, "Specify S3 URLs for workDir and outdir parameters on AWSBatch!"
  // Check workDir/outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!workflow.workDir.startsWith('s3:') || !params.outdir.startsWith('s3:')) exit 1, "Workdir or Outdir not on S3 - specify S3 Buckets for each to run on AWSBatch!"
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

// Custom trimming options
params.clip_r1 = 0
params.clip_r2 = 0
params.three_prime_clip_r1 = 0
params.three_prime_clip_r2 = 0

/*
 * Create a channel for input read files
 */
if(params.readPaths){
    if(params.singleEnd){
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0])]] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { read_files_fastqc; read_files_trimming }
    } else {
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0]), file(row[1][1])]] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { read_files_fastqc; read_files_trimming }
    }
} else {
    Channel
        .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --singleEnd on the command line." }
        .into { read_files_fastqc; read_files_trimming }
}


// Header log info
log.info nfcoreHeader()
def summary = [:]
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Reads']            = params.reads
summary['Fasta Ref']        = params.fasta
summary['Data Type']        = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if( params.notrim ){
    summary['Trimming Step'] = 'Skipped'
} else {
    summary["Trim 5' R1"] = params.clip_r1
    summary["Trim 5' R2"] = params.clip_r2
    summary["Trim 3' R1"] = params.three_prime_clip_r1
    summary["Trim 3' R2"] = params.three_prime_clip_r2
}
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-scgs-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'gongyh/nf-core-scgs Workflow Summary'
    section_href: 'https://github.com/gongyh/nf-core-scgs'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v != null ? v : '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}


/*
 * Parse software version numbers
 */
process get_software_versions {
    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    trim_galore --version &> v_trim_galore.txt
    bowtie2 --version &> v_bowtie2.txt
    samtools --version &> v_samtools.txt
    bedtools --version &> v_bedtools.txt
    preseq &> v_preseq.txt
    qualimap -h &> v_qualimap.txt
    picard MarkDuplicates --version > v_picard.txt
    gatk3 -version > v_gatk.txt
    Rscript -e 'print(packageVersion("AneuFinder"))' &> v_AneuFinder.txt
    spades.py --version &> v_spades.txt
    quast.py --version &> v_quast.txt
    multiqc --version &> v_multiqc.txt
    source activate py27 && conda list | grep monovar | awk '{print \$2}' &> v_monovar.txt
    scrape_software_versions.py > software_versions_mqc.yaml
    """
}

/*
 * Store reference
 */
process save_reference {
    publishDir path: "${params.outdir}/reference_genome", mode: 'copy'

    input:
    file fasta from fasta
    file gff from gff

    output:
    file "genome.fa"
    file "genome.gff"
    file "*.bed"
    file "genome.bed" into genome_circlize

    script:
    """
    ln -s ${fasta} genome.fa
    ln -s ${gff} genome.gff
    source activate py27
    fa2bed.py genome.fa
    cat genome.gff | grep \$'\tgene\t' | bedtools sort | cut -f1,4,5,7 > genes.bed
    """
}

/*
 * STEP 0 - Split Build Bowtie2 index if necessary
 */

bowtie2 = params.genome ? params.genomes[ params.genome ].bowtie2 ?: false : false
if(bowtie2){
    bowtie2_index = file(bowtie2) 
} else {
process prepare_bowtie2 {
    publishDir path: "${params.outdir}/reference_genome", mode: 'copy'

    input:
    file fasta from fasta

    output:
    file "Bowtie2Index" into bowtie2_index

    script:
    """
    mkdir -p Bowtie2Index; cd Bowtie2Index
    ln -s ../${fasta} genome.fa
    bowtie2-build genome.fa genome
    """
}
}

/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$name"
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

    input:
    set val(name), file(reads) from read_files_fastqc

    output:
    file "*_fastqc.{zip,html}" into fastqc_results

    script:
    """
    fastqc -q $reads
    """
}

/*
 * STEP 2 - Trim Galore!
 */
if(params.notrim){
    trimmed_reads = read_files_trimming
    trimgalore_results = []
    trimgalore_fastqc_reports = []
} else {
    process trim_galore {
        tag "$name"
        publishDir "${params.outdir}/trim_galore", mode: 'copy',
            saveAs: {filename ->
                if (filename.indexOf("_fastqc") > 0) "FastQC/$filename"
                else if (filename.indexOf("trimming_report.txt") > 0) "logs/$filename"
                else params.saveTrimmed ? filename : null
            }

        input:
        set val(name), file(reads) from read_files_trimming

        output:
        file '*.fq.gz' into trimmed_reads, trimmed_reads_for_spades
        file '*trimming_report.txt' into trimgalore_results
        file "*_fastqc.{zip,html}" into trimgalore_fastqc_reports

        script:
        c_r1 = params.clip_r1 > 0 ? "--clip_r1 ${params.clip_r1}" : ''
        c_r2 = params.clip_r2 > 0 ? "--clip_r2 ${params.clip_r2}" : ''
        tpc_r1 = params.three_prime_clip_r1 > 0 ? "--three_prime_clip_r1 ${params.three_prime_clip_r1}" : ''
        tpc_r2 = params.three_prime_clip_r2 > 0 ? "--three_prime_clip_r2 ${params.three_prime_clip_r2}" : ''
        if (params.singleEnd) {
            """
            trim_galore --fastqc --gzip $c_r1 $tpc_r1 $reads
            """
        } else {
            """
            trim_galore --paired --fastqc --gzip $c_r1 $c_r2 $tpc_r1 $tpc_r2 $reads
            """
        }
    }
}

/*
 * STEP 3 - align with bowtie2
 */
process bowtie2 {
    tag "$prefix"
    publishDir path: { params.saveAlignedIntermediates ? "${params.outdir}/bowtie2" : params.outdir }, mode: 'copy',
               saveAs: {filename -> params.saveAlignedIntermediates ? filename : null }

    input:
    file reads from trimmed_reads
    file index from bowtie2_index

    output:
    file '*.bam' into bb_bam

    script:
    prefix = reads[0].toString() - ~/(\.R1)?(_1)?(_R1)?(_trimmed)?(_combined)?(\.1_val_1)?(_R1_val_1)?(\.fq)?(\.fastq)?(\.gz)?$/
    R1 = reads[0].toString()
    R2 = reads[1].toString()
    filtering = params.allow_multi_align ? '' : "| samtools view -b -q 40 -F 4 -F 256 -"
    """
    bowtie2 --no-mixed --no-discordant -X 1000 -x ${index}/genome -p ${task.cpus} -1 $R1 -2 $R2 | samtools view -bT $index - $filtering > ${prefix}.bam
    """
}

/*
 * STEP 4 - post-alignment processing
 */
process samtools {
    tag "${prefix}"
    publishDir path: "${pp_outdir}", mode: 'copy',
               saveAs: { filename ->
                   if (filename.indexOf(".stats.txt") > 0) "stats/$filename"
                   else params.saveAlignedIntermediates ? filename : null
               }

    input:
    file bam from bb_bam

    output:
    file '*.markdup.bam' into bam_for_qualimap, bam_for_monovar, bam_for_realign, bam_for_quast
    file '*.markdup.bam.bai' into bai_for_qualimap, bai_for_monovar, bai_for_realign, bai_for_quast
    file '*.markdup.bed' into bed_for_circlize, bed_for_preseq
    file '*.stats.txt' into samtools_stats

    script:
    pp_outdir = "${params.outdir}/bowtie2"
    prefix = bam.baseName
    """
    samtools sort -o ${prefix}.sorted.bam $bam
    samtools index ${prefix}.sorted.bam
    picard MarkDuplicates I=${prefix}.sorted.bam O=${prefix}.markdup.bam M=metrics.txt AS=true
    samtools index ${prefix}.markdup.bam
    bedtools bamtobed -i ${prefix}.markdup.bam | sort -k 1,1 -k 2,2n -k 3,3n -k 6,6 > ${prefix}.markdup.bed
    samtools stats ${prefix}.markdup.bam > ${prefix}.stats.txt
    """
}

/*
 * STEP 4.1 - predicting library complexity and genome coverage using preseq
 */
process preseq {
    tag "${prefix}"
    publishDir path: "${pp_outdir}", mode: 'copy',
               saveAs: { filename ->
                   if (filename.indexOf(".txt") > 0) "$filename" else null }

    input:
    file sbed from bed_for_preseq

    output:
    file '*.txt' into preseq_for_multiqc

    script:
    pp_outdir = "${params.outdir}/preseq"
    prefix = sbed.toString() - ~/(\.markdup\.bed)?(\.markdup)?(\.bed)?$/
    """
    preseq c_curve -P -s 1e+4 -o ${prefix}_c.txt $sbed
    preseq lc_extrap -o ${prefix}_lc.txt $sbed
    preseq gc_extrap -o ${prefix}_gc.txt $sbed
    """
}

/*
 * STEP 4.2 - quality control of alignment sequencing data using QualiMap 
 */
process qualimap {
    publishDir path: "${pp_outdir}", mode: 'copy'

    input:
    file ("*") from bam_for_qualimap.collect()
    file ("*") from bai_for_qualimap.collect()
    file gff from gff

    output:
    file '*.markdup_stats' into qualimap_for_multiqc
    file 'multi-bamqc'

    script:
    pp_outdir = "${params.outdir}/qualimap"
    """
    ls *.markdup.bam > bams.txt
    cat bams.txt | awk '{split(\$1,a,".markdup.bam"); print a[1]"\t"\$1}' > inputs.txt
    qualimap multi-bamqc -r -c -d inputs.txt -gff $gff -outdir multi-bamqc
    """
}

/*
 * STEP 4.3 - SNV detection using MonoVar
 */
process monovar {
    publishDir path: "${pp_outdir}", mode: 'copy',
               saveAs: { filename ->
                   if (filename.indexOf(".vcf") > 0) "$filename" else null }

    input:
    file ("*") from bam_for_monovar.collect()
    file ("*") from bai_for_monovar.collect()
    file fa from fasta

    output:
    file 'monovar.vcf' into monovar_vcf

    script:
    pp_outdir = "${params.outdir}/monovar"
    """
    source activate py27
    ls *.bam > bams.txt
    samtools mpileup -BQ0 -d 10000 -q 40 -f $fa -b bams.txt | monovar -f $fa -o monovar.vcf -m ${task.cpus} -b bams.txt
    """
}

/*                                                                              
 * STEP 4.4.0 - Realign InDels                                
 */                                                                             
process IndelRealign {
    tag "${prefix}"                                                            
    publishDir path: "${pp_outdir}", mode: 'copy'                               
                                                                                
    input:                                                                      
    file bam from bam_for_realign
    file fa from fasta                           
                                                                                
    output:                                                                     
    file '*.realign.bam' into bam_for_aneufinder
    file '*.realign.bam.bai' into bai_for_aneufinder                                           
                                                                                
    script:                                                                     
    pp_outdir = "${params.outdir}/gatk"
    prefix = bam.toString() - ~/(\.markdup\.bam)?(\.markdup)?(\.bam)?$/                                   
    """
    wget "https://software.broadinstitute.org/gatk/download/auth?package=GATK-archive&version=3.8-0-ge9d806836" -O GenomeAnalysisTK-3.8.tar.bz2
    gatk3-register ./GenomeAnalysisTK-3.8.tar.bz2
    samtools faidx $fa
    picard CreateSequenceDictionary R=$fa
    picard AddOrReplaceReadGroups I=$bam O=${prefix}.bam RGLB=lib RGPL=illumina RGPU=run RGSM=${prefix}
    samtools index ${prefix}.bam
    gatk3 -T RealignerTargetCreator -R $fa -I ${prefix}.bam -o indels.intervals
    gatk3 -T IndelRealigner -R $fa -I ${prefix}.bam -targetIntervals indels.intervals -o ${prefix}.realign.bam
    samtools index ${prefix}.realign.bam                                      
    """                                                                         
}

/*
 * STEP 4.4.1 - CNV detection using AneuFinder
 */
process aneufinder {
    publishDir path: "${pp_outdir}", mode: 'copy'

    input:
    file ("bams/*") from bam_for_aneufinder.collect()
    file ("bams/*") from bai_for_aneufinder.collect()

    output:
    file 'CNV_output' into cnv_output

    script:
    pp_outdir = "${params.outdir}/aneufinder"
    """
    aneuf.R ./bams CNV_output ${task.cpus}
    """
}

/*
 * STEP 5 - Prepare files for Circlize
 */
process circlize {
    tag "${prefix}"
    publishDir "${params.outdir}/circlize", mode: 'copy', 
            saveAs: {filename ->
                if (filename.indexOf(".bed") > 0) "$filename" else null
            }

    input:
    file sbed from bed_for_circlize
    file refbed from genome_circlize

    output:
    file "${prefix}-cov200.bed"
    
    shell:
    prefix = sbed.toString() - ~/(\.markdup\.bed)?(\.markdup)?(\.bed)?$/
    """
    bedtools makewindows -b $refbed -w 200 > genome.200.bed
    bedtools coverage -b $sbed -a genome.200.bed | sort -k 1V,1 -k 2n,2 -k 3n,3 > ${prefix}-cov200.bed
    """
}

/*
 * STEP 6 - Assemble using SPAdes
 */
process spades {
    tag "${prefix}"
    publishDir path: "${params.outdir}/spades", mode: 'copy'

    input:
    file clean_reads from trimmed_reads_for_spades

    output:
    file "${prefix}.contigs.fasta" into contigs_for_quast, contigs_for_checkm

    script:
    prefix = clean_reads[0].toString() - ~/(\.R1)?(_1)?(_R1)?(_trimmed)?(_combined)?(\.1_val_1)?(_R1_val_1)?(\.fq)?(\.fastq)?(\.gz)?$/
    R1 = clean_reads[0].toString()
    R2 = clean_reads[1].toString()
    """
    spades.py --sc -1 $R1 -2 $R2 --careful -t ${task.cpus} -o ${prefix}.spades_out
    ln -s ${prefix}.spades_out/contigs.fasta ${prefix}.contigs.fasta
    """
}

/*
 * STEP 7 - Evaluation using QUAST
 */
process quast {
    publishDir path: "${params.outdir}", mode: 'copy'

    input:
    file fasta from fasta
    file gff from gff
    file ("*") from contigs_for_quast.collect()
    file ("*") from bam_for_quast.collect()
    file ("*") from bai_for_quast.collect()

    output:
    file "quast/report.tsv" into quast_report
    file "quast"

    script:
    euk = params.euk ? "-e" : ""
    """
    contigs=\$(ls *.contigs.fasta | paste -sd " " -)
    bam=\$(ls *.markdup.bam | paste -sd "," -)
    quast.py -o quast -R $fasta -G $gff -m 50 -t ${task.cpus} $euk --circos --rna-finding -b --bam \$bam --no-sv --no-read-stats \$contigs
    """
}

/*
 * STEP 8 - Completeness and contamination evaluation using CheckM
 */
process checkm {
   publishDir "${params.outdir}/CheckM", mode: 'copy'
   
   input:
   file ('spades/*') from contigs_for_checkm.collect()

   output:
   file 'spades_checkM.txt' into checkm_report

   script:
   checkm_wf = params.genus ? "taxonomy_wf" : "lineage_wf"
   """
   source activate py27
   if [ \"${checkm_wf}\" == \"taxonomy_wf\" ]; then
     checkm taxonomy_wf -t ${task.cpus} -f spades_checkM.txt -x fasta genus ${params.genus} spades spades_checkM
   else
     checkm lineage_wf -t ${task.cpus} -f spades_checkM.txt -x fasta spades spades_checkM
   fi
   """
}

/*
 * STEP 9 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config
    file ('fastqc/*') from fastqc_results.collect()
    file ('software_versions/*') from software_versions_yaml
    file ('trimgalore/*') from trimgalore_results.collect()
    file ('fastqc2/*') from trimgalore_fastqc_reports.collect()
    file ('samtools/*') from samtools_stats.collect()
    file ('preseq/*') from preseq_for_multiqc.collect()
    file ('*') from qualimap_for_multiqc.collect()
    file ('quast/*') from quast_report.collect()
    file workflow_summary from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"

    script:
    """
    multiqc -f --config $multiqc_config .
    """
}



/*
 * STEP 10 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}



/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[gongyh/nf-core-scgs] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[gongyh/nf-core-scgs] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.maxMultiqcEmailFileSize)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList){
                log.warn "[gongyh/nf-core-scgs] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[gongyh/nf-core-scgs] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[gongyh/nf-core-scgs] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[gongyh/nf-core-scgs] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    if(workflow.success){
        log.info "${c_purple}[gongyh/nf-core-scgs]${c_green} Pipeline complete${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[gongyh/nf-core-scgs]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  gongyh/nf-core-scgs v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}

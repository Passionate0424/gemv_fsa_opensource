# 关于进行在线编译 CI 的诸项要求

本仓库仅限用户用于在 **集成电路创新创业大赛-龙芯中科杯** 的**初赛**中，通过 Gitlab CI/CD持续集成 功能，将Soc设计源码在本平台上经由服务器进行 Vivado工程产物（Bitstream）的生成。具体工作流程如下：

1. 用户/参赛选手将源码添加到 rtl文件夹 （此处指gitlab仓库中的rtl文件夹，并非发布包）中，将源码推送到仓库，触发由 .gitlab-ci.yml 限定的流水线工作。
2. 在流水线作业中，系统将用户放在指定位置的源码**添加到初赛发布包**中，用vivado 2019.2执行 create_project.tcl 创建工程，随后执行 bit.tcl ，进行综合Synthesis、实现Implementation、生成比特流Generate Bitstream，并提取工程产物。
3. 用户在 FPGA在线实验平台**绑定访问令牌(Access token)与仓库ID**，选择产物进行评测，并进行有效标记。

# 本仓库的提交要求：

1. 上传文件的类型
   a. **以源代码（如 Verilog/VHDL）形式提供的模块**
   b. 以网表（Netlist）形式提供的模块
   c. 以.xci （Xilinx Core Instance）形式提供 Vivado IP 的配置文件
2. 上传文件的内容
   初赛包提供了基本的soc内容，且开发过程为增量开发，因此在仓库中只需要上传**对原环境（发布包）进行修改/增加**的文件。
   示例：
   a. “对于发布包而言，我修改了soc_top.v。”  将这一个文件替换到仓库的对应文件。
   b. “对于发布包而言，我修改了soc_top.v和ip/confreg/confreg.v” 将这些文件添加/替换到仓库的对应位置/文件。
3. 上传文件的位置
   **文件的存放位置遵从发布包中的工程结构与源码存放位置。**
   soc_top.v 放置在 rtl/ 中。
   IP 每一个须单独存放在 rtl/ip/<ip_name> 中，具体可提供以下三种类型
   示例：

   1. confreg.v 放置在 rtl/ip/confreg。
   2. int_ctrl.v 放置在 rtl/ip/confreg。
   3. ip_name.xci放置在 rtl/ip/<ip_name>。（如有添加IP的需要）
4. 仓库中所有分支的.gitlab-ci.yml用于控制CI流程的配置文件，**无法被修改**。
5. 本仓库的 main/master 分支为受保护分支，**用户推送提交请创建/使用其他分支**，分支名自定义。
6. 请勿向 main/master 分支 进行Pull Request，请求不会被接受。**用户如质疑仓库结构合理性，请联系管理员。**
7. 橙色云平台的提交内容与本平台**互不干涉，亦不形成互补**。工程源码及各类展示材料如ppt,word,video等材料请上传到 集创赛作品提交平台-橙色云。

"""Check signature handling and preservation of existing shader outputs."""
import unittest
from depth_variant import with_depth_bias

FIXTURE='''define void @main() {
  call void @dx.op.storeOutput.f32(i32 5, i32 0, i32 0, i8 0, float 1.000000e+00)
  ret void
}
!dx.entryPoints = !{!10}
!10 = !{void ()* @main, !"main", !11, null, null}
!11 = !{!12, !13, null}
!12 = !{!14, !18}
!13 = !{!15, !19}
!14 = !{i32 6, !"SV_Position", i8 9, i8 3, !16, i8 4, i32 1, i8 4, i32 6, i8 0, !17}
!15 = !{i32 0, !"SV_Target", i8 9, i8 16, !16, i8 0, i32 1, i8 4, i32 0, i8 0, !17}
!16 = !{i32 0}
!17 = !{i32 3, i8 1}
!18 = !{i32 2, !"TEXCOORD", i8 9, i8 0, !16, i8 1, i32 1, i8 4, i32 2, i8 0, !17}
!19 = !{i32 1, !"SV_Coverage", i8 5, i8 66, !16, i8 0, i32 1, i8 1, i32 -1, i8 0, !17}
'''

class DepthVariantTests(unittest.TestCase):
    def test_colours_and_shared_input_tags_preserved(self):
        result=with_depth_bias(FIXTURE,512)
        original_store=next(l for l in FIXTURE.splitlines() if 'call void @dx.op.storeOutput' in l)
        self.assertIn(original_store,result)
        self.assertIn('!17 = !{i32 3, i8 1}',result)
        self.assertIn('!18 = '+FIXTURE.split('!18 = ')[1].splitlines()[0],result)
        self.assertIn('i32 6, i32 0, i8 2',result)
        self.assertIn('i32 2, !"SV_Depth"',result)
        self.assertIn('!13 = !{!15, !19, !20}',result)
        self.assertIn('%water_bias_bits, 512',result)
        self.assertEqual(result.count('!"SV_Depth"'),1)
    def test_zero_bias_exports_original_position_depth(self):
        result=with_depth_bias(FIXTURE,0)
        self.assertNotIn('add i32',result)
        self.assertIn('i32 2, i32 0, i8 0, float %water_bias_depth',result)
    def test_existing_depth_and_second_application_rejected(self):
        with self.assertRaises(ValueError): with_depth_bias(with_depth_bias(FIXTURE,64),64)
        with self.assertRaises(ValueError): with_depth_bias(FIXTURE.replace('SV_Target','SV_Depth'),64)
    def test_unexpected_signatures_and_returns_rejected(self):
        for invalid in (FIXTURE.replace('SV_Position','OTHER'),FIXTURE.replace('!dx.entryPoints = !{!10}','!dx.entryPoints = !{!10, !10}'),FIXTURE.replace('  ret void','  ret void\n}\ndefine void @extra() {\n  ret void')):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError): with_depth_bias(invalid,64)
    def test_invalid_bias_rejected(self):
        for value in (-1,8193,0.5):
            with self.subTest(value=value):
                with self.assertRaises(ValueError): with_depth_bias(FIXTURE,value)

if __name__=='__main__': unittest.main()
